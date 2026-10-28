import Foundation

/// What an `.ipa` declares about itself, read out of the archive without
/// unpacking it: the app's `Info.plist`, the Mach-O headers of its main
/// executable, any extensions, the embedded provisioning profile — and what
/// all of it means for installing it on this iPhone.
///
/// The Sideloaded apps page only needs a bundle ID and a name (`IPALibrary`),
/// so it reads the one plist. This goes further for the Inspect page, whose
/// job is to say *before* an install what will happen, and why it might not.
struct IPAReport {

    /// One nested `.appex` (or watch app) inside the archive.
    struct Extension: Identifiable, Equatable {
        let name: String
        let bundleID: String?
        let minimumOS: String?
        /// Path inside the archive, e.g. `Payload/X.app/PlugIns/Y.appex`.
        let path: String
        /// False when the extension has no `embedded.mobileprovision` of its
        /// own — signing still issues one, but a profile copied from the .ipa
        /// can't be reused for it.
        let hasProfile: Bool

        var id: String { path }
    }

    /// Something worth saying before the install runs.
    struct Issue: Identifiable {
        enum Severity {
            /// The install can't work: signing it would waste an App ID.
            case blocker
            /// It will install, but probably not do what was expected.
            case warning
            /// Context that isn't a problem.
            case note
        }

        let severity: Severity
        let title: String
        let detail: String

        var id: String { title }
    }

    let url: URL
    let fileName: String
    let fileSize: Int64

    // MARK: Identity

    let bundleID: String
    let name: String
    let version: String?
    let build: String?
    /// The icon at the largest size the archive carries, if one could be read.
    let icon: Data?

    // MARK: Compatibility

    /// `MinimumOSVersion` as published, e.g. "15.0".
    let minimumOS: String?
    /// `CFBundleSupportedPlatforms`, normally just `["iPhoneOS"]`.
    let platforms: [String]
    /// `UIDeviceFamily` as words: "iPhone", "iPad", …
    let deviceFamilies: [String]
    /// Every architecture in the main executable, fat slices included.
    let architectures: [String]
    /// The `minos` the executable itself carries, which can differ from the
    /// plist's (a lax `MinimumOSVersion` is common on repackaged IPAs).
    let executableMinimumOS: String?
    /// True for an App Store build: its code is FairPlay-encrypted, so it runs
    /// only as installed from the App Store. Re-signing it leaves the
    /// executable undecryptable, and it crashes on launch.
    let isEncrypted: Bool

    // MARK: Signing

    let extensions: [Extension]
    /// The profile already inside the .ipa, if any. It's informational only:
    /// signing issues a fresh one for this Apple ID.
    let profile: ProvisioningProfile?

    // MARK: Contents

    let fileCount: Int
    let unpackedBytes: Int
    /// SHA-256 of the whole file in lowercase hex, or nil if it couldn't be
    /// read. This is the number to compare against a source's published hash.
    let sha256: String?

    // MARK: Verdict

    let issues: [Issue]

    /// True when nothing in the report rules the install out.
    var installable: Bool { !issues.contains { $0.severity == .blocker } }

    /// One-line size, e.g. "24.6 MB".
    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    /// The same for what it unpacks to.
    var unpackedText: String {
        ByteCountFormatter.string(fromByteCount: Int64(unpackedBytes), countStyle: .file)
    }
}

// MARK: - Reading an IPA

enum IPAInspector {

    /// Reads `url` and describes it. Nil means the file isn't a readable IPA at
    /// all (not a zip, or no `Payload/<name>.app/Info.plist` inside).
    ///
    /// Synchronous and IO-bound — call it off the main actor. `hashing` reads
    /// the whole file again for its SHA-256, which a 200 MB IPA doesn't want on
    /// every redraw, so the page asks for it once.
    static func inspect(_ url: URL, hashing: Bool = true) -> IPAReport? {
        guard let files = IPALibrary.archiveFiles(at: url) else { return nil }
        guard let app = mainApp(in: files) else { return nil }
        let prefix = app.prefix

        func data(_ path: String, max: Int = 8 << 20) -> Data? {
            guard let file = files.first(where: { $0.path == path }) else { return nil }
            guard file.size <= max else { return nil }
            return IPALibrary.contents(of: file, in: url)
        }

        guard let plistData = data(prefix + "Info.plist"),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil),
              let info = plist as? [String: Any]
        else { return nil }

        let bundleID = (info["CFBundleIdentifier"] as? String) ?? ""
        let display = info["CFBundleDisplayName"] as? String
        let bundleName = info["CFBundleName"] as? String
        let name = display?.isEmpty == false ? display!
            : (bundleName?.isEmpty == false ? bundleName! : (bundleID.isEmpty ? app.name : bundleID))

        let executable = (info["CFBundleExecutable"] as? String) ?? app.name
        let binary = data(prefix + executable, max: 256 << 20).flatMap(machO)
        let minimumOS = info["MinimumOSVersion"] as? String
            ?? (info["LSMinimumSystemVersion"] as? String)
        let platforms = info["CFBundleSupportedPlatforms"] as? [String] ?? []
        let families = (info["UIDeviceFamily"] as? [Int] ?? []).compactMap(deviceFamily)
        let extensions = self.extensions(in: files, under: prefix, data: data)
        let profile = data(prefix + "embedded.mobileprovision", max: 1 << 20)
            .flatMap(ProvisioningProfile.init(data:))

        let unpacked = files.reduce(0) { $0 + $1.size }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64 ?? 0

        var report = IPAReport(
            url: url,
            fileName: url.lastPathComponent,
            fileSize: size,
            bundleID: bundleID,
            name: name,
            version: info["CFBundleShortVersionString"] as? String,
            build: info["CFBundleVersion"] as? String,
            icon: icon(in: files, under: prefix, data: data),
            minimumOS: minimumOS,
            platforms: platforms,
            deviceFamilies: families,
            architectures: binary?.archs ?? [],
            executableMinimumOS: binary?.minimumOS,
            isEncrypted: binary?.encrypted ?? false,
            extensions: extensions,
            profile: profile,
            fileCount: files.count,
            unpackedBytes: unpacked,
            sha256: hashing ? IPALibrary.sha256(of: url) : nil,
            issues: [])
        report = report.with(issues: issues(for: report))
        return report
    }

    /// The same report with the hash filled in, keeping everything already read
    /// (the page computes it after showing the rest).
    static func addingHash(to report: IPAReport) -> IPAReport {
        report.with(sha256: IPALibrary.sha256(of: report.url))
    }

    // MARK: The app in the archive

    /// `Payload/<name>.app`, found through its own `Info.plist`: exactly three
    /// path components, which leaves out the plists inside extensions and
    /// frameworks.
    private static func mainApp(in files: [IPALibrary.ArchiveFile]) -> (name: String, prefix: String)? {
        for file in files {
            let parts = file.path.split(separator: "/").map(String.init)
            guard parts.count == 3, parts[0] == "Payload",
                  parts[1].hasSuffix(".app"), parts[2] == "Info.plist" else { continue }
            return (String(parts[1].dropLast(4)), parts[0] + "/" + parts[1] + "/")
        }
        return nil
    }

    /// Nested `.appex` bundles (and watch apps), each with whatever its own
    /// `Info.plist` says.
    private static func extensions(in files: [IPALibrary.ArchiveFile], under prefix: String,
                                   data: (String, Int) -> Data?) -> [IPAReport.Extension] {
        var out: [IPAReport.Extension] = []
        var seen = Set<String>()
        for file in files where file.path.hasPrefix(prefix) && file.path.hasSuffix("/Info.plist") {
            let path = String(file.path.dropLast("/Info.plist".count))
            let leaf = path.split(separator: "/").last.map(String.init) ?? path
            guard leaf.hasSuffix(".appex")
                    || (leaf.hasSuffix(".app") && path.contains("/Watch/"))
            else { continue }
            guard seen.insert(path).inserted else { continue }
            let plist: [String: Any]? = data(path + "/Info.plist", 1 << 20).flatMap { raw in
                (try? PropertyListSerialization.propertyList(from: raw, format: nil)) as? [String: Any]
            }
            out.append(IPAReport.Extension(name: String(leaf.split(separator: ".").first ?? ""),
                                           bundleID: plist?["CFBundleIdentifier"] as? String,
                                           minimumOS: plist?["MinimumOSVersion"] as? String,
                                           path: path,
                                           hasProfile: files.contains {
                                               $0.path == path + "/embedded.mobileprovision"
                                           }))
        }
        return out
    }

    /// The largest icon-shaped PNG in the app bundle, for the page's hero.
    private static func icon(in files: [IPALibrary.ArchiveFile], under prefix: String,
                             data: (String, Int) -> Data?) -> Data? {
        let candidates = files.filter { file in
            guard file.path.hasPrefix(prefix), file.path.lowercased().hasSuffix(".png") else { return false }
            // Only the app's own resources, not an asset catalog's innards.
            guard file.path.split(separator: "/").count == 3 else { return false }
            let name = (file.path as NSString).lastPathComponent.lowercased()
            return name.hasPrefix("appicon") || name.hasPrefix("icon")
        }
        guard let biggest = candidates.max(by: { $0.size < $1.size }),
              biggest.size > 0, biggest.size < 4 << 20 else { return nil }
        return data(biggest.path, biggest.size)
    }

    // MARK: The verdict

    private static func issues(for report: IPAReport) -> [IPAReport.Issue] {
        var out: [IPAReport.Issue] = []

        if report.bundleID.isEmpty {
            out.append(.init(severity: .blocker,
                             title: L("No bundle identifier"),
                             detail: L("The app's Info.plist has no CFBundleIdentifier, so there's nothing to register an App ID for.")))
        }
        if !report.platforms.isEmpty, !report.platforms.contains("iPhoneOS") {
            out.append(.init(severity: .blocker,
                             title: L("Not an iOS app"),
                             detail: L("It's built for %@, which this iPhone can't run.", report.platforms.joined(separator: ", "))))
        }
        if !report.deviceFamilies.isEmpty, !report.deviceFamilies.contains("iPhone") {
            out.append(.init(severity: .warning,
                             title: L("Made for another device"),
                             detail: L("It lists %@ as supported, not iPhone. It may install and run in a compatibility window, or not at all.",
                                       report.deviceFamilies.joined(separator: ", "))))
        }
        if report.architectures.isEmpty {
            out.append(.init(severity: .warning,
                             title: L("No executable found"),
                             detail: L("The app's CFBundleExecutable is missing from the archive, or isn't a Mach-O binary. Signing will fail on it.")))
        } else if !report.architectures.contains(where: { $0.hasPrefix("arm64") }) {
            out.append(.init(severity: .blocker,
                             title: L("No arm64 code"),
                             detail: L("It only carries %@. This iPhone is arm64, and iOS 27 runs nothing else.",
                                       report.architectures.joined(separator: ", "))))
        }
        if report.isEncrypted {
            out.append(.init(severity: .blocker,
                             title: L("App Store encrypted"),
                             detail: L("The executable is FairPlay-encrypted (cryptid 1). Decryption happens only on the device that bought it; re-signed with your Apple ID it stays encrypted and crashes on launch. Use a decrypted build.")))
        }
        if let needed = report.minimumOS, let major = Int(needed.split(separator: ".").first ?? ""),
           major > ProcessInfo.processInfo.operatingSystemVersion.majorVersion {
            out.append(.init(severity: .blocker,
                             title: L("Needs iOS %@", needed),
                             detail: L("This iPhone runs iOS %ld, so the install completes and the app refuses to launch.",
                                       ProcessInfo.processInfo.operatingSystemVersion.majorVersion)))
        }
        if let plistOS = report.minimumOS, let binaryOS = report.executableMinimumOS,
           plistOS != binaryOS, comparison(plistOS, binaryOS) != .orderedAscending {
            out.append(.init(severity: .note,
                             title: L("Minimum iOS differs"),
                             detail: L("The Info.plist says %@ but the executable was built for %@. The higher one is what applies.",
                                       plistOS, binaryOS)))
        }
        if report.profile == nil, report.extensions.isEmpty {
            out.append(.init(severity: .note,
                             title: L("No embedded profile"),
                             detail: L("Normal for a fresh build. Signing issues one for your Apple ID either way.")))
        }
        if let profile = report.profile, profile.isExpired {
            out.append(.init(severity: .note,
                             title: L("Embedded profile has expired"),
                             detail: L("It expired %@. SideInstaller signs with a new profile, so this doesn't stop the install.",
                                       profile.expirationDate.map { dateText($0) } ?? L("earlier"))))
        }
        for `extension` in report.extensions where !`extension`.hasProfile {
            out.append(.init(severity: .warning,
                             title: L("%@ has no profile of its own", `extension`.name),
                             detail: L("Signing issues one, and writes it into the extension. If the app still refuses to launch with a provisioning-profile error in its logs, this extension is why.")))
        }
        if report.extensions.count > 4 {
            out.append(.init(severity: .note,
                             title: L("%ld extensions", report.extensions.count),
                             detail: L("Each one is registered as its own App ID, and a free Apple ID has a small allowance.")))
        }
        if report.fileSize > 0, report.unpackedBytes > 0,
           report.unpackedBytes > report.fileSize * 24 / 10 {
            out.append(.init(severity: .note,
                             title: L("Unpacks to %@", report.unpackedText),
                             detail: L("About %ld× the download. Both the signed copy and the extracted bundle are written to disk, so keep that much free.",
                                       report.unpackedBytes / max(Int(report.fileSize), 1))))
        }
        return out
    }

    /// "1.2" vs "1.10" by number, not by string.
    private static func comparison(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }

    private static func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    private static func deviceFamily(_ value: Int) -> String? {
        switch value {
        case 1: return "iPhone"
        case 2: return "iPad"
        case 3: return L("Apple TV")
        case 4: return L("Apple Watch")
        case 6: return L("Vision Pro")
        default: return nil
        }
    }
}

// MARK: - Mach-O

/// The parts of a Mach-O header worth reading before an install: what it runs
/// on, what iOS it was built for, and whether its code is still encrypted.
struct MachOInfo {
    var archs: [String] = []
    var minimumOS: String?
    var encrypted = false
}

/// Reads the executable's own headers. Fat binaries are walked slice by slice,
/// so an x86_64 + arm64 build reports both — and still counts as arm64-capable.
func machO(_ data: Data) -> MachOInfo? {
    let bytes = [UInt8](data.prefix(64 << 20))
    guard bytes.count >= 28 else { return nil }
    switch bigEndian32(bytes, 0) {
    case 0xCAFE_BABE:
        return fatMachO(bytes, bigEndian: true, is64: false)
    case 0xCAFE_BABF:
        return fatMachO(bytes, bigEndian: true, is64: true)
    case 0xBEBA_FECA:
        return fatMachO(bytes, bigEndian: false, is64: false)
    case 0xBFBA_FECA:
        return fatMachO(bytes, bigEndian: false, is64: true)
    default:
        return thinMachO(bytes, 0)
    }
}

private func fatMachO(_ bytes: [UInt8], bigEndian: Bool, is64: Bool) -> MachOInfo? {
    let count = Int(read32(bytes, 4, bigEndian: bigEndian))
    guard count > 0, count < 64 else { return nil }
    let stride = is64 ? 32 : 20
    var out = MachOInfo()
    for index in 0..<count {
        let at = 8 + index * stride
        guard at + stride <= bytes.count else { break }
        let cpu = read32(bytes, at, bigEndian: bigEndian)
        let subtype = read32(bytes, at + 4, bigEndian: bigEndian)
        let offset = is64 ? Int(read64(bytes, at + 8, bigEndian: bigEndian))
                          : Int(read32(bytes, at + 8, bigEndian: bigEndian))
        out.archs.append(architecture(cpu: cpu, subtype: subtype))
        guard let slice = thinMachO(bytes, offset) else { continue }
        out.encrypted = out.encrypted || slice.encrypted
        if out.minimumOS == nil { out.minimumOS = slice.minimumOS }
    }
    return out.archs.isEmpty ? nil : out
}

private func thinMachO(_ bytes: [UInt8], _ base: Int) -> MachOInfo? {
    guard base >= 0, base + 28 <= bytes.count else { return nil }
    let magic = bigEndian32(bytes, base)
    let bigEndian: Bool
    let is64: Bool
    switch magic {
    case 0xFEED_FACE:   bigEndian = false; is64 = false     // MH_MAGIC
    case 0xFEED_FACF:   bigEndian = false; is64 = true      // MH_MAGIC_64
    case 0xCEFA_EDFE:   bigEndian = true;  is64 = false     // MH_CIGAM
    case 0xCFFA_EDFE:   bigEndian = true;  is64 = true      // MH_CIGAM_64
    default: return nil
    }
    let cpu = read32(bytes, base + 4, bigEndian: bigEndian)
    let subtype = read32(bytes, base + 8, bigEndian: bigEndian)
    let commandCount = Int(read32(bytes, base + 16, bigEndian: bigEndian))
    var out = MachOInfo(archs: [architecture(cpu: cpu, subtype: subtype)])
    var cursor = base + (is64 ? 32 : 28)
    // A hostile or corrupt file can claim thousands; the bound keeps this cheap.
    for _ in 0..<min(commandCount, 4096) {
        guard cursor + 8 <= bytes.count else { break }
        let command = read32(bytes, cursor, bigEndian: bigEndian)
        let size = Int(read32(bytes, cursor + 4, bigEndian: bigEndian))
        guard size >= 8, cursor + size <= bytes.count else { break }
        switch command {
        case 0x32:      // LC_BUILD_VERSION
            let platform = read32(bytes, cursor + 8, bigEndian: bigEndian)
            if out.minimumOS == nil, platform == 2 {            // PLATFORM_IOS
                out.minimumOS = versionText(read32(bytes, cursor + 12, bigEndian: bigEndian))
            }
        case 0x25:      // LC_VERSION_MIN_IPHONEOS
            if out.minimumOS == nil {
                out.minimumOS = versionText(read32(bytes, cursor + 8, bigEndian: bigEndian))
            }
        case 0x21, 0x2C:    // LC_ENCRYPTION_INFO, LC_ENCRYPTION_INFO_64
            if read32(bytes, cursor + 16, bigEndian: bigEndian) != 0 { out.encrypted = true }
        default:
            break
        }
        cursor += size
    }
    return out
}

/// `cputype`/`cpusubtype` as the arch name Xcode shows.
private func architecture(cpu: UInt32, subtype: UInt32) -> String {
    switch cpu {
    case 0x0100_000C:                                   // CPU_TYPE_ARM64
        // CPU_SUBTYPE_ARM64E is 2 with the pointer-authentication ABI bit.
        return (subtype & 0x00FF_FFFF) == 2 ? "arm64e" : "arm64"
    case 0x0200_000C: return "arm64_32"
    case 12:          return "armv7"
    case 0x0100_0007: return "x86_64"
    case 7:           return "i386"
    default:          return String(format: "cpu 0x%x", cpu)
    }
}

/// A `minos`/`version` field: xxxx.yy.zz packed into 32 bits.
private func versionText(_ value: UInt32) -> String {
    let major = value >> 16
    let minor = (value >> 8) & 0xFF
    let patch = value & 0xFF
    return patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
}

private func bigEndian32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
    guard at >= 0, at + 4 <= bytes.count else { return 0 }
    return UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16
        | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
}

private func read32(_ bytes: [UInt8], _ at: Int, bigEndian: Bool) -> UInt32 {
    let value = bigEndian32(bytes, at)
    return bigEndian ? value : value.byteSwapped
}

private func read64(_ bytes: [UInt8], _ at: Int, bigEndian: Bool) -> UInt64 {
    let high = read32(bytes, at, bigEndian: bigEndian)
    let low = read32(bytes, at + 4, bigEndian: bigEndian)
    return bigEndian ? UInt64(high) << 32 | UInt64(low) : UInt64(low) << 32 | UInt64(high)
}

// MARK: - Keeping a report and changing one field

extension IPAReport {
    /// The same report with selected fields replaced, so the parser can build
    /// it in one pass and the page can fill in the hash later.
    func with(sha256: String? = nil, issues: [Issue]? = nil) -> IPAReport {
        IPAReport(url: url, fileName: fileName, fileSize: fileSize,
                  bundleID: bundleID, name: name, version: version, build: build, icon: icon,
                  minimumOS: minimumOS, platforms: platforms, deviceFamilies: deviceFamilies,
                  architectures: architectures, executableMinimumOS: executableMinimumOS,
                  isEncrypted: isEncrypted, extensions: extensions, profile: profile,
                  fileCount: fileCount, unpackedBytes: unpackedBytes,
                  sha256: sha256 ?? self.sha256, issues: issues ?? self.issues)
    }
}
