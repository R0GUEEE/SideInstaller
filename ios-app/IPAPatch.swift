import Compression
import Foundation

/// Rewrites a custom `.ipa` in place before it's signed: a new identity, no
/// extensions, and tweaks loaded into the app's main executable.
///
/// The archive is rewritten rather than unpacked and re-zipped: every entry the
/// change doesn't touch is copied as its original compressed bytes, so a 100 MB
/// IPA costs a few megabytes of work. Only the files that change are inflated
/// (and written back stored).
///
/// Everything here is idempotent. Import the same build twice with the same
/// configuration and the second pass finds the identity already applied and the
/// tweaks already loaded, and writes nothing.
enum IPAPatch {

    struct Outcome {
        var applied: [String] = []
        var warnings: [String] = []
    }

    enum PatchError: LocalizedError {
        case notAnIPA
        case zip64
        case corrupt(String)
        case noHeaderRoom(String)
        case write(String)

        var errorDescription: String? {
            switch self {
            case .notAnIPA:
                return L("That file can't be read as an .ipa.")
            case .zip64:
                return L("That .ipa uses ZIP64, which SideInstaller can't rewrite. Unpack and repack it without ZIP64 first.")
            case .corrupt(let path):
                return L("The archive is damaged around %@.", path)
            case .noHeaderRoom(let name):
                return L("%@ has no space in its Mach-O header for another library. iOS binaries built without header padding can't take an injected tweak.", name)
            case .write(let reason):
                return L("Couldn't write the rebuilt .ipa: %@", reason)
            }
        }
    }

    /// Applies `config` to the archive at `url`, replacing it on success.
    ///
    /// `injectors` are the injection frameworks the user supplied; the ones a
    /// package's `Depends` asks for are loaded before the tweaks themselves.
    static func apply(_ config: AppConfig, injectors: [TweakInjector],
                      to url: URL) throws -> Outcome {
        guard config.isActive else { return Outcome() }
        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
              size > 22
        else { throw PatchError.notAnIPA }
        let entries = try directory(source, fileSize: size)
        guard let app = mainApp(in: entries) else { throw PatchError.notAnIPA }
        let prefix = app.prefix

        var outcome = Outcome()

        // What to replace (contents) and what to leave out entirely.
        var replacements: [String: Data] = [:]
        var replacedModes: [String: UInt32] = [:]
        var droppedPrefixes: [String] = []

        if config.stripExtensions { droppedPrefixes.append(prefix + "PlugIns/") }
        if config.stripWatchApp { droppedPrefixes.append(prefix + "Watch/") }
        if !config.disabledExtensions.isEmpty {
            for name in config.disabledExtensions {
                droppedPrefixes.append(prefix + "PlugIns/" + name + "/")
            }
        }

        // MARK: Info.plist
        let plistPath = prefix + "Info.plist"
        guard let plistEntry = entries.first(where: { $0.name == plistPath }),
              let plistData = try contents(of: plistEntry, in: source),
              var info = (try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil))
                as? [String: Any]
        else { throw PatchError.notAnIPA }

        var plistChanged = false
        let newBundleID = config.bundleIdentifier.trimmed
        if !newBundleID.isEmpty, (info["CFBundleIdentifier"] as? String) != newBundleID {
            info["CFBundleIdentifier"] = newBundleID
            plistChanged = true
            outcome.applied.append(L("Bundle ID set to %@", newBundleID))
        }
        let newName = config.displayName.trimmed
        if !newName.isEmpty, (info["CFBundleDisplayName"] as? String) != newName {
            info["CFBundleDisplayName"] = newName
            info["CFBundleName"] = newName
            plistChanged = true
            outcome.applied.append(L("Name set to %@", newName))
        }
        let newVersion = config.version.trimmed
        if !newVersion.isEmpty, (info["CFBundleShortVersionString"] as? String) != newVersion {
            info["CFBundleShortVersionString"] = newVersion
            plistChanged = true
            outcome.applied.append(L("Version set to %@", newVersion))
        }
        let newBuild = config.build.trimmed
        if !newBuild.isEmpty, (info["CFBundleVersion"] as? String) != newBuild {
            info["CFBundleVersion"] = newBuild
            plistChanged = true
            outcome.applied.append(L("Build set to %@", newBuild))
        }
        // Keys added by hand: `CFBundleIcons`, a URL scheme, `itunesstored`…
        for edit in config.plistEdits {
            guard let value = edit.object else {
                outcome.warnings.append(L("%@: “%@” isn't a valid value", edit.key, edit.value))
                continue
            }
            let key = edit.key.trimmed
            guard !key.isEmpty else { continue }
            if let current = info[key], valuesMatch(current, value) { continue }
            info[key] = value
            plistChanged = true
            outcome.applied.append(L("Info.plist: %@ = %@", key, edit.value))
        }
        if plistChanged {
            guard let data = try? PropertyListSerialization.data(fromPropertyList: info,
                                                                 format: .binary, options: 0)
            else { throw PatchError.corrupt(plistPath) }
            replacements[plistPath] = data
            replacedModes[plistPath] = plistEntry.externalAttributes
        }

        // MARK: Entitlements
        // The signature the installer writes carries the profile's entitlements,
        // so these are what the build *declares* — the file the signer reads
        // when it looks for an app's own list.
        if !config.entitlements.isEmpty {
            let entitlementsPath = prefix + "archived-expanded-entitlements.xcent"
            var entitlements: [String: Any] = [:]
            if let existing = entries.first(where: { $0.name == entitlementsPath }),
               let raw = try contents(of: existing, in: source),
               let decoded = try? PropertyListSerialization.propertyList(from: raw, options: [], format: nil)
                as? [String: Any] {
                entitlements = decoded
            }
            for edit in config.entitlements {
                guard let value = edit.object else { continue }
                let key = edit.key.trimmed
                guard !key.isEmpty else { continue }
                entitlements[key] = value
                outcome.applied.append(L("Entitlement: %@", key))
            }
            if let data = try? PropertyListSerialization.data(fromPropertyList: entitlements,
                                                             format: .binary, options: 0) {
                replacements[entitlementsPath] = data
                replacedModes[entitlementsPath] = entries.first { $0.name == entitlementsPath }?
                    .externalAttributes ?? (0o100644 << 16)
            }
        }

        // MARK: Nested bundle identifiers
        // An extension keeps its own App ID, and iOS requires it to sit under
        // the app's, so a renamed app renames its extensions with it.
        if !newBundleID.isEmpty {
            for (path, suffix) in nestedBundles(in: entries, under: prefix, dropping: droppedPrefixes) {
                guard let entry = entries.first(where: { $0.name == path + "Info.plist" }),
                      let raw = try contents(of: entry, in: source),
                      var nested = (try? PropertyListSerialization.propertyList(from: raw, options: [], format: nil))
                        as? [String: Any]
                else { continue }
                let wanted = newBundleID + "." + suffix
                guard (nested["CFBundleIdentifier"] as? String) != wanted else { continue }
                nested["CFBundleIdentifier"] = wanted
                guard let data = try? PropertyListSerialization.data(fromPropertyList: nested,
                                                                     format: .binary, options: 0)
                else { continue }
                replacements[path + "Info.plist"] = data
                outcome.applied.append(L("%@ renamed to %@", suffix, wanted))
            }
        }

        // MARK: Tweaks
        var injected: [String: Data] = [:]
        if !config.tweaks.isEmpty {
            let executableName = (info["CFBundleExecutable"] as? String) ?? app.name
            let executablePath = prefix + executableName
            guard let entry = entries.first(where: { $0.name == executablePath }),
                  var binary = try contents(of: entry, in: source)
            else { throw PatchError.corrupt(executablePath) }

            let libraries = resolve(config.tweaks, injectors: injectors, outcome: &outcome)
            var loaded = Set<String>()
            for library in libraries {
                guard loaded.insert(library.fileName).inserted else {
                    outcome.warnings.append(L("%@ is already loaded by another tweak", library.fileName))
                    continue
                }
                let result = try MachOInject.inject(library: library.loadPath, weak: library.weak,
                                                    into: binary, name: executableName)
                binary = result.data
                switch result.state {
                case .injected:
                    outcome.applied.append(L("Injected %@", library.displayName))
                case .alreadyLoaded:
                    outcome.warnings.append(L("%@ was already loaded", library.displayName))
                }
                // The library goes beside any frameworks the app already ships;
                // `@executable_path/Frameworks` is where iOS apps load from.
                injected[prefix + "Frameworks/" + library.fileName] = library.data
            }
            replacements[executablePath] = binary
            replacedModes[executablePath] = entry.externalAttributes
        }

        // MARK: Write it back
        let output = try Writer(source: source)
        for entry in entries {
            if droppedPrefixes.contains(where: { entry.name.hasPrefix($0) }) { continue }
            if entry.name.hasSuffix("/") { continue }
            if let data = replacements[entry.name] {
                try output.add(name: entry.name, data: data,
                               attributes: replacedModes[entry.name] ?? entry.externalAttributes)
            } else {
                try output.copy(entry)
            }
        }
        for (path, data) in injected where !entries.contains(where: { $0.name == path }) {
            try output.add(name: path, data: data, attributes: 0o100755 << 16)
        }
        let rebuilt = try output.finish()

        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: rebuilt)
        } catch {
            try? FileManager.default.removeItem(at: rebuilt)
            throw PatchError.write(error.localizedDescription)
        }
        if config.stripExtensions { outcome.applied.append(L("App extensions removed")) }
        if config.stripWatchApp { outcome.applied.append(L("Watch app removed")) }
        for name in config.disabledExtensions where !config.stripExtensions {
            outcome.applied.append(L("%@ removed", name))
        }
        return outcome
    }

    /// One library as it will be injected: where the executable loads it from,
    /// its bytes, and whether it's optional.
    private struct LibraryToInject {
        let displayName: String
        let fileName: String
        let loadPath: String
        let weak: Bool
        let data: Data
    }

    /// Everything to load, injectors first: each `.dylib` as it is, and each
    /// `.deb` unpacked into the libraries it installs.
    private static func resolve(_ tweaks: [Tweak], injectors: [TweakInjector],
                                outcome: inout Outcome) -> [LibraryToInject] {
        var out: [LibraryToInject] = []
        var injectorsAdded = Set<TweakInjectorKind>()

        /// The framework a package depends on, loaded once, ahead of the tweak:
        /// the library to inject, or the warning saying it isn't here.
        func injectorLibrary(_ kind: TweakInjectorKind,
                             added: inout Set<TweakInjectorKind>) -> (library: LibraryToInject?, warning: String?) {
            guard added.insert(kind).inserted else { return (nil, nil) }
            guard let injector = injectors.first(where: { $0.kind == kind }),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: injector.path),
                                       options: .uncached)
            else { return (nil, kind.title) }
            return (LibraryToInject(displayName: injector.kind.title,
                                    fileName: injector.fileName,
                                    loadPath: "@executable_path/Frameworks/\(injector.fileName)",
                                    weak: false,
                                    data: data), nil)
        }

        func add(_ name: String, _ fileName: String, _ data: Data, weak: Bool) {
            // A library built for another slice can't run here, and injecting it
            // would only make the app crash on launch.
            guard let image = machO(data) else {
                outcome.warnings.append(L("%@ isn't a Mach-O library", fileName))
                return
            }
            guard image.archs.contains(where: { $0.hasPrefix("arm64") }) else {
                outcome.warnings.append(L("%@ is built for %@ — this iPhone needs arm64",
                                          fileName, image.archs.joined(separator: ", ")))
                return
            }
            out.append(LibraryToInject(displayName: name, fileName: fileName,
                                       loadPath: "@executable_path/Frameworks/\(fileName)",
                                       weak: weak, data: data))
        }

        for tweak in tweaks {
            switch tweak.kind {
            case .dylib:
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: tweak.path),
                                           options: .uncached) else {
                    outcome.warnings.append(L("%@ is missing, so it wasn't injected", tweak.name))
                    continue
                }
                // A hand-added library may still say which framework it needs,
                // so its injector is loaded first like a package's.
                if let kind = tweak.requiresInjector {
                    let injector = injectorLibrary(kind, added: &injectorsAdded)
                    if let library = injector.library { out.append(library) }
                    if injector.warning != nil {
                        outcome.warnings.append(L("%@ needs %@, which isn't added under Injectors",
                                                  tweak.name, kind.title))
                    }
                }
                add(tweak.name, (tweak.path as NSString).lastPathComponent, data, weak: tweak.weak)

            case .deb:
                guard let package = try? DebArchive.read(URL(fileURLWithPath: tweak.path)) else {
                    outcome.warnings.append(L("%@ couldn't be unpacked", tweak.name))
                    continue
                }
                // The injector the package depends on comes first, or the tweak
                // has nothing to hook with.
                if let kind = package.requiredInjector {
                    let injector = injectorLibrary(kind, added: &injectorsAdded)
                    if let library = injector.library { out.append(library) }
                    if injector.warning != nil {
                        outcome.warnings.append(L("%@ needs %@, which isn't added under Injectors",
                                                  tweak.name, kind.title))
                    }
                }
                guard !package.libraries.isEmpty else {
                    outcome.warnings.append(L("%@ carries no library to inject", tweak.name))
                    continue
                }
                for library in package.libraries {
                    add("\(tweak.name) · \(library.fileName)", library.fileName,
                        library.data, weak: tweak.weak)
                }
            }
        }
        return out
    }

    /// Whether a plist value already equals what an edit wants to set.
    private static func valuesMatch(_ current: Any, _ wanted: Any) -> Bool {
        switch (current, wanted) {
        case let (a as String, b as String):   return a == b
        case let (a as NSNumber, b as NSNumber): return a == b
        case let (a as [String], b as [String]): return a == b
        default: return false
        }
    }

    // MARK: - The app inside the archive

    /// `Payload/<name>.app`, found through its own `Info.plist`.
    private static func mainApp(in entries: [Entry]) -> (name: String, prefix: String)? {
        for entry in entries {
            let parts = entry.name.split(separator: "/").map(String.init)
            guard parts.count == 3, parts[0] == "Payload",
                  parts[1].hasSuffix(".app"), parts[2] == "Info.plist" else { continue }
            return (String(parts[1].dropLast(4)), parts[0] + "/" + parts[1] + "/")
        }
        return nil
    }

    /// Nested bundles as (path with a trailing slash, suffix to put under the
    /// new bundle ID). A `.appex` becomes `<newID>.<its own name>`, and a watch
    /// app becomes `<newID>.watchkitapp`.
    private static func nestedBundles(in entries: [Entry], under prefix: String,
                                      dropping dropped: [String]) -> [(String, String)] {
        var out: [(String, String)] = []
        var seen = Set<String>()
        for entry in entries where entry.name.hasPrefix(prefix) && entry.name.hasSuffix("/Info.plist") {
            let path = String(entry.name.dropLast("Info.plist".count))
            guard !dropped.contains(where: { path.hasPrefix($0) }) else { continue }
            let leaf = path.split(separator: "/").last.map(String.init) ?? path
            let isExtension = leaf.hasSuffix(".appex")
            let isWatch = leaf.hasSuffix(".app") && path.contains("/Watch/")
            guard isExtension || isWatch else { continue }
            guard seen.insert(path).inserted else { continue }
            let stem = String(leaf.split(separator: ".").first ?? "")
            out.append((path, isWatch ? stem + ".watchkitapp" : stem))
        }
        return out
    }

    // MARK: - Reading the archive

    struct Entry {
        let name: String
        let method: UInt16
        let flags: UInt16
        let crc: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let externalAttributes: UInt32
        let localHeaderOffset: Int
    }

    private static func directory(_ handle: FileHandle, fileSize: Int) throws -> [Entry] {
        let tailLength = min(fileSize, 65_557)
        guard (try? handle.seek(toOffset: UInt64(fileSize - tailLength))) != nil,
              let tail = try? handle.readToEnd(),
              let found = tail.range(of: Data([0x50, 0x4B, 0x05, 0x06]), options: .backwards)
        else { throw PatchError.notAnIPA }
        let record = tail[found.lowerBound...]
        guard record.count >= 22 else { throw PatchError.notAnIPA }
        let offset = u32(record, 16)
        let length = u32(record, 12)
        guard offset != 0xFFFF_FFFF, length != 0xFFFF_FFFF else { throw PatchError.zip64 }
        guard length > 0, offset + length <= fileSize,
              (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let raw = try? handle.read(upToCount: length), raw.count == length
        else { throw PatchError.notAnIPA }

        var out: [Entry] = []
        var cursor = 0
        while cursor + 46 <= raw.count {
            let header = raw[(raw.startIndex + cursor)...]
            guard u32(header, 0) == 0x0201_4B50 else { break }
            let nameLength = u16(header, 28)
            let extraLength = u16(header, 30)
            let commentLength = u16(header, 32)
            let total = 46 + nameLength + extraLength + commentLength
            guard cursor + total <= raw.count else { break }
            let start = header.startIndex + 46
            if let name = String(data: header[start..<(start + nameLength)], encoding: .utf8) {
                let compressed = u32(header, 20)
                let uncompressed = u32(header, 24)
                out.append(Entry(name: name,
                                 method: UInt16(truncatingIfNeeded: u16(header, 10)),
                                 flags: UInt16(truncatingIfNeeded: u16(header, 8)),
                                 crc: UInt32(truncatingIfNeeded: u32(header, 16)),
                                 compressedSize: compressed,
                                 uncompressedSize: uncompressed,
                                 externalAttributes: UInt32(truncatingIfNeeded: u32(header, 38)),
                                 localHeaderOffset: u32(header, 42)))
            }
            cursor += total
        }
        guard !out.isEmpty else { throw PatchError.notAnIPA }
        return out
    }

    /// A member's uncompressed bytes.
    private static func contents(of entry: Entry, in handle: FileHandle) throws -> Data? {
        guard entry.uncompressedSize > 0, entry.uncompressedSize < (1 << 30),
              (try? handle.seek(toOffset: UInt64(entry.localHeaderOffset))) != nil,
              let header = try? handle.read(upToCount: 30), header.count == 30,
              u32(header, 0) == 0x0403_4B50
        else { return nil }
        // The local header repeats the name and carries its own extra field,
        // whose length routinely differs from the central directory's.
        let dataOffset = entry.localHeaderOffset + 30 + u16(header, 26) + u16(header, 28)
        guard (try? handle.seek(toOffset: UInt64(dataOffset))) != nil,
              let raw = try? handle.read(upToCount: entry.compressedSize),
              raw.count == entry.compressedSize
        else { return nil }
        switch entry.method {
        case 0: return raw
        case 8: return inflate(raw, to: entry.uncompressedSize)
        default: return nil
        }
    }

    /// `COMPRESSION_ZLIB` is raw DEFLATE, which is what a zip member holds.
    private static func inflate(_ data: Data, to size: Int) -> Data? {
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            guard let target = dst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return data.withUnsafeBytes { src -> Int in
                guard let source = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(target, size, source, data.count, nil,
                                                 COMPRESSION_ZLIB)
            }
        }
        return written == size ? out : nil
    }

    // MARK: - Writing the archive

    /// Writes a fresh zip: entries copied verbatim keep their compressed bytes,
    /// replaced ones are written stored.
    private final class Writer {
        /// One member as written, and what its central-directory record needs.
        private struct Record {
            let name: String
            let flags: UInt16
            let method: UInt16
            let crc: UInt32
            let compressed: Int
            let uncompressed: Int
            let attributes: UInt32
            let offset: Int
        }

        private let source: FileHandle
        private let handle: FileHandle
        private let path: URL
        private var offset = 0
        private var records: [Record] = []

        init(source: FileHandle) throws {
            self.source = source
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("patch-\(UUID().uuidString).ipa")
            guard FileManager.default.createFile(atPath: destination.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: destination)
            else { throw PatchError.write("couldn't create a temporary file") }
            self.handle = handle
            self.path = destination
        }

        /// A file written from memory, stored (uncompressed).
        func add(name: String, data: Data, attributes: UInt32) throws {
            let crc = CRC32.checksum(data)
            try write(localHeader(name: name, method: 0, crc: crc,
                                  compressed: data.count, uncompressed: data.count))
            try write(data)
            records.append(Record(name: name, flags: 0, method: 0, crc: crc,
                                  compressed: data.count, uncompressed: data.count,
                                  attributes: attributes, offset: offset))
            offset += 30 + name.utf8.count + data.count
        }

        /// An existing member, copied as its original compressed bytes.
        func copy(_ entry: Entry) throws {
            guard (try? source.seek(toOffset: UInt64(entry.localHeaderOffset))) != nil,
                  let local = try? source.read(upToCount: 30), local.count == 30
            else { throw PatchError.corrupt(entry.name) }
            let dataOffset = entry.localHeaderOffset + 30 + u16(local, 26) + u16(local, 28)
            let header = localHeader(name: entry.name, method: entry.method, crc: entry.crc,
                                     compressed: entry.compressedSize,
                                     uncompressed: entry.uncompressedSize)
            guard (try? source.seek(toOffset: UInt64(dataOffset))) != nil,
                  let compressed = try? source.read(upToCount: entry.compressedSize),
                  compressed.count == entry.compressedSize
            else { throw PatchError.corrupt(entry.name) }
            try write(header)
            try write(compressed)
            // A data descriptor in the original is dropped with the flags bit
            // that announced it: the sizes are in the header now.
            records.append(Record(name: entry.name, flags: entry.flags & ~0x0008,
                                  method: entry.method, crc: entry.crc,
                                  compressed: entry.compressedSize,
                                  uncompressed: entry.uncompressedSize,
                                  attributes: entry.externalAttributes, offset: offset))
            offset += header.count + compressed.count
        }

        /// Writes the central directory and returns the finished file.
        func finish() throws -> URL {
            guard records.count < 65_535 else { throw PatchError.zip64 }
            let directoryOffset = offset
            var directory = Data()
            for record in records {
                var central = Data()
                let nameBytes = Array(record.name.utf8)
                central.append(contentsOf: le32(0x0201_4B50))
                central.append(contentsOf: le16(0x031E))     // made by: unix, 3.0
                central.append(contentsOf: le16(20))         // needed: 2.0
                central.append(contentsOf: le16(record.flags))
                central.append(contentsOf: le16(record.method))
                central.append(contentsOf: le16(0))          // time
                central.append(contentsOf: le16(0x21))       // date: 1980-01-01
                central.append(contentsOf: le32(record.crc))
                central.append(contentsOf: le32(UInt32(record.compressed)))
                central.append(contentsOf: le32(UInt32(record.uncompressed)))
                central.append(contentsOf: le16(UInt16(nameBytes.count)))
                central.append(contentsOf: le16(0))          // extra
                central.append(contentsOf: le16(0))          // comment
                central.append(contentsOf: le16(0))          // disk
                central.append(contentsOf: le16(0))          // internal attributes
                central.append(contentsOf: le32(record.attributes))
                central.append(contentsOf: le32(UInt32(record.offset)))
                central.append(contentsOf: nameBytes)
                directory.append(central)
            }
            try write(directory)
            var end = Data()
            end.append(contentsOf: le32(0x0605_4B50))
            end.append(contentsOf: le16(0))                  // this disk
            end.append(contentsOf: le16(0))                  // disk with the directory
            end.append(contentsOf: le16(UInt16(records.count)))
            end.append(contentsOf: le16(UInt16(records.count)))
            end.append(contentsOf: le32(UInt32(directory.count)))
            end.append(contentsOf: le32(UInt32(directoryOffset)))
            end.append(contentsOf: le16(0))                  // comment length
            try write(end)
            try handle.close()
            return path
        }

        private func localHeader(name: String, method: UInt16, crc: UInt32,
                                 compressed: Int, uncompressed: Int) -> Data {
            var header = Data()
            let nameBytes = Array(name.utf8)
            header.append(contentsOf: le32(0x0403_4B50))
            header.append(contentsOf: le16(20))              // needed: 2.0
            header.append(contentsOf: le16(0))               // flags
            header.append(contentsOf: le16(method))
            header.append(contentsOf: le16(0))               // time
            header.append(contentsOf: le16(0x21))            // date
            header.append(contentsOf: le32(crc))
            header.append(contentsOf: le32(UInt32(compressed)))
            header.append(contentsOf: le32(UInt32(uncompressed)))
            header.append(contentsOf: le16(UInt16(nameBytes.count)))
            header.append(contentsOf: le16(0))               // extra length
            header.append(contentsOf: nameBytes)
            return header
        }

        private func write(_ data: Data) throws {
            do { try handle.write(contentsOf: data) }
            catch { throw PatchError.write(error.localizedDescription) }
        }
    }

    // MARK: - Little-endian helpers

    private static func u16(_ data: Data, _ at: Int) -> Int {
        let i = data.startIndex + at
        guard i >= data.startIndex, i + 1 < data.endIndex else { return 0 }
        return Int(data[i]) | Int(data[i + 1]) << 8
    }

    private static func u32(_ data: Data, _ at: Int) -> Int {
        u16(data, at) | u16(data, at + 2) << 16
    }

    private static func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private static func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
         UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }
}

// MARK: - CRC-32

/// The checksum zip stores per member.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buffer in
            for byte in buffer.bindMemory(to: UInt8.self) {
                crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Mach-O

/// Adds one `LC_LOAD_DYLIB` (or `LC_LOAD_WEAK_DYLIB`) to a Mach-O binary.
///
/// Adding a load command means writing 24+ bytes where the header has room: the
/// gap between the end of the load commands and the first section's data. Xcode
/// leaves one — the start of `__TEXT` is page-aligned — and injecting into it
/// changes nothing else in the file, so no offsets need rewriting.
enum MachOInject {

    enum State { case injected, alreadyLoaded }

    struct Result {
        let data: Data
        let state: State
    }

    static func inject(library path: String, weak: Bool, into binary: Data,
                       name: String) throws -> Result {
        var bytes = [UInt8](binary)
        guard bytes.count > 32 else { throw IPAPatch.PatchError.corrupt(name) }
        let magic = be32(bytes, 0)
        let bigEndian: Bool
        let is64: Bool
        // Read big-endian, so the byte order it comes back in is the file's.
        switch magic {
        case 0xCFFA_EDFE: bigEndian = false; is64 = true      // MH_MAGIC_64, little-endian file
        case 0xCEFA_EDFE: bigEndian = false; is64 = false
        case 0xFEED_FACF: bigEndian = true;  is64 = true
        case 0xFEED_FACE: bigEndian = true;  is64 = false
        default: throw IPAPatch.PatchError.corrupt(name)
        }

        func read32(_ at: Int) -> UInt32 {
            let value = be32(bytes, at)
            return bigEndian ? value : value.byteSwapped
        }
        func write32(_ value: UInt32, _ at: Int) {
            let ordered = bigEndian ? value : value.byteSwapped
            bytes[at] = UInt8((ordered >> 24) & 0xFF)
            bytes[at + 1] = UInt8((ordered >> 16) & 0xFF)
            bytes[at + 2] = UInt8((ordered >> 8) & 0xFF)
            bytes[at + 3] = UInt8(ordered & 0xFF)
        }

        let headerSize = is64 ? 32 : 28
        var commandCount = Int(read32(16))
        var commandsSize = Int(read32(20))
        guard headerSize + commandsSize <= bytes.count else {
            throw IPAPatch.PatchError.corrupt(name)
        }

        let loadWeak: UInt32 = 0x8000_0018
        let loadStrong: UInt32 = 0x0000_000C
        var firstSectionOffset = Int.max
        var cursor = headerSize

        for _ in 0..<commandCount {
            guard cursor + 8 <= bytes.count else { break }
            let command = read32(cursor)
            let size = Int(read32(cursor + 4))
            guard size >= 8, cursor + size <= headerSize + commandsSize else { break }
            if command == loadStrong || command == loadWeak {
                // dylib_command: name is an offset from the command's start.
                let nameOffset = Int(read32(cursor + 8))
                if nameOffset > 0, nameOffset < size {
                    let start = cursor + nameOffset
                    let end = min(start + 1024, cursor + size)
                    if let found = String(bytes: bytes[start..<end], encoding: .utf8) {
                        let loaded = found.split(separator: "\0").first.map(String.init) ?? ""
                        if loaded == path { return Result(data: binary, state: .alreadyLoaded) }
                    }
                }
            }
            // LC_SEGMENT_64 / LC_SEGMENT: the first section's file offset is
            // where the header's room ends.
            if command == 0x19 || command == 0x1 {
                let segmentNameEnd = cursor + 18
                if segmentNameEnd <= bytes.count,
                   String(bytes: bytes[(cursor + 8)..<segmentNameEnd], encoding: .utf8)
                    .map({ $0.hasPrefix("__TEXT") }) ?? false {
                    let sectionCount = Int(read32(cursor + (command == 0x19 ? 64 : 48)))
                    let sectionsStart = cursor + (command == 0x19 ? 72 : 56)
                    if sectionCount > 0 {
                        let offsetAt = sectionsStart + (command == 0x19 ? 48 : 40)
                        if offsetAt + 4 <= bytes.count {
                            let offset = Int(read32(offsetAt))
                            if offset > 0 { firstSectionOffset = min(firstSectionOffset, offset) }
                        }
                    }
                }
            }
            cursor += size
        }

        // The command: dylib_command header, then the path and its terminator.
        let pathBytes = Array(path.utf8)
        let commandSize = align(24 + pathBytes.count + 1, to: 8)
        let commandsEnd = headerSize + commandsSize
        let room = firstSectionOffset == Int.max ? 0 : firstSectionOffset - commandsEnd
        guard room >= commandSize else {
            throw IPAPatch.PatchError.noHeaderRoom(name)
        }

        var command = [UInt8](repeating: 0, count: commandSize)
        func put32(_ value: UInt32, _ at: Int) {
            let ordered = bigEndian ? value : value.byteSwapped
            command[at] = UInt8((ordered >> 24) & 0xFF)
            command[at + 1] = UInt8((ordered >> 16) & 0xFF)
            command[at + 2] = UInt8((ordered >> 8) & 0xFF)
            command[at + 3] = UInt8(ordered & 0xFF)
        }
        put32(weak ? loadWeak : loadStrong, 0)
        put32(UInt32(commandSize), 4)
        put32(24, 8)                     // name offset
        put32(0, 12)                     // timestamp
        put32(0, 16)                     // current version
        put32(0, 20)                     // compatibility version
        for (index, byte) in pathBytes.enumerated() { command[24 + index] = byte }

        // The new command goes where the old load commands ended; whatever gap
        // is left over stays zeroed, which is the padding codesign hashes.
        bytes.replaceSubrange(commandsEnd..<commandsEnd + commandSize, with: command)
        commandCount += 1
        commandsSize += commandSize
        write32(UInt32(commandCount), 16)
        write32(UInt32(commandsSize), 20)
        return Result(data: Data(bytes), state: .injected)
    }

    private static func align(_ value: Int, to boundary: Int) -> Int {
        (value + boundary - 1) / boundary * boundary
    }

    private static func be32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16
            | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
    }
}
