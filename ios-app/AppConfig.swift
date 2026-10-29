import Combine
import Foundation

/// Which injection framework a tweak expects. A package's `Depends` names one,
/// and the app has to load that framework beside the tweak.
enum TweakInjectorKind: String, Codable, CaseIterable, Identifiable {
    case ellekit
    case substrate
    case libhooker
    case substitute

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ellekit:    return "ElleKit"
        case .substrate:  return "CydiaSubstrate"
        case .libhooker:  return "libhooker"
        case .substitute: return "Substitute"
        }
    }

    /// What a package's `Depends` calls it.
    var packageName: String {
        switch self {
        case .ellekit:    return "ellekit"
        case .substrate:  return "mobilesubstrate"
        case .libhooker:  return "libhooker"
        case .substitute: return "substitute"
        }
    }

    /// The library file name to look for when one is added by hand.
    var fileName: String {
        switch self {
        case .ellekit:    return "ellekit.dylib"
        case .substrate:  return "CydiaSubstrate"
        case .libhooker:  return "libhooker.dylib"
        case .substitute: return "libsubstitute.dylib"
        }
    }
}

extension TweakInjectorKind {
    /// The framework a library is built against, read from the libraries it
    /// links. A tweak compiled against Substrate names `libsubstrate.dylib`
    /// even when nothing in its package says so, which is the only dependency
    /// signal a bare `.dylib` has.
    static func detected(inLibraries libraries: [String]) -> TweakInjectorKind? {
        let names = libraries.map { ($0 as NSString).lastPathComponent.lowercased() }
        if names.contains(where: { $0.contains("ellekit") }) { return .ellekit }
        if names.contains(where: { $0.contains("libhooker") }) { return .libhooker }
        if names.contains(where: { $0.contains("substitute") }) { return .substitute }
        if names.contains(where: { $0.contains("substrate") }) { return .substrate }
        return nil
    }
}

/// A library the user supplied that provides one of those frameworks. Bundling
/// them isn't possible, so they're added from a copy the user already has.
struct TweakInjector: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: TweakInjectorKind
    /// Path to the copy in Application Support.
    var path: String
    /// The name it gets inside the app's `Frameworks` folder.
    var fileName: String
}

/// A tweak — a `.dylib` on its own, or a `.deb` that carries one or more.
struct Tweak: Codable, Identifiable, Equatable {

    enum Kind: String, Codable {
        case dylib
        case deb
    }

    var id = UUID()
    /// What the list calls it: the file's name, or the package's name.
    var name: String
    /// The copy in Application Support (a `.dylib` or the `.deb` itself).
    var path: String
    var kind: Kind
    /// For a `.dylib`: where the executable should load it from.
    var loadPath: String
    /// Load it if it's there rather than requiring it.
    var weak = false
    /// The injector the package says it needs, worked out when it was added.
    var requiresInjector: TweakInjectorKind?
    /// The package's own identifier, when it came out of a `.deb` — what makes
    /// "is there a newer release?" a question that can be answered.
    var identifier: String?
    /// The package version it was added at.
    var version: String?
    /// The repository it came from, when it was added from the browser, so the
    /// update check asks the repository that published it first.
    var repository: String?

    var isDeb: Bool { kind == .deb }

    /// What the list shows beside the name: `1.4` for a package, nothing for a
    /// bare library.
    var versionText: String? {
        guard let version, !version.isEmpty else { return nil }
        return version
    }

    /// The repository's host, for a caption: `havoc.app` rather than a URL.
    var repositoryHost: String? {
        guard let repository, let host = URL(string: repository)?.host else { return nil }
        return host
    }

    /// How a repository package is recognised in the configuration: its
    /// identifier when it has one, otherwise the file name.
    func matches(fileName: String, identifier: String?) -> Bool {
        if let mine = self.identifier, !mine.isEmpty, let identifier, !identifier.isEmpty {
            return mine == identifier
        }
        return (path as NSString).lastPathComponent.lowercased() == fileName.lowercased()
    }
}

/// One addition to a plist: a top-level key, its type, and its value.
struct PlistEdit: Codable, Identifiable, Equatable {

    enum Kind: String, Codable, CaseIterable, Identifiable {
        case string, boolean, integer, array

        var id: String { rawValue }

        var title: String {
            switch self {
            case .string:  return L("Text")
            case .boolean: return L("Switch")
            case .integer: return L("Number")
            case .array:   return L("List")
            }
        }
    }

    var id = UUID()
    var key: String
    var kind: Kind = .string
    var value: String = ""

    /// The value as a plist object, or nil when it can't be one.
    var object: Any? {
        let name = key.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        switch kind {
        case .string:
            return value
        case .boolean:
            return (value as NSString).boolValue
        case .integer:
            guard let number = Int(value) else { return nil }
            return number
        case .array:
            let items = value.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            return items
        }
    }
}

/// What to change about a custom `.ipa` on the way to being signed: its
/// identity, its plists, which extensions survive, the entitlements it
/// declares, and the tweaks loaded into it.
struct AppConfig: Codable, Equatable {

    /// The four identity fields, which follow the build unless overridden.
    enum IdentityField: String, CaseIterable, Codable {
        case bundleIdentifier, displayName, version, build

        var title: String {
            switch self {
            case .bundleIdentifier: return L("Bundle ID")
            case .displayName:      return L("Display name")
            case .version:          return L("Version")
            case .build:            return L("Build")
            }
        }
    }

    /// New `CFBundleIdentifier`. Extensions and watch apps are re-prefixed.
    var bundleIdentifier = ""
    var displayName = ""
    var version = ""
    var build = ""
    /// Extra or replacement top-level keys in the app's `Info.plist`.
    var plistEdits: [PlistEdit] = []
    /// Keys written into the app's archived entitlements file.
    var entitlements: [PlistEdit] = []
    /// `PlugIns` entries to leave out, by their bundle's name (`Widget.appex`).
    var disabledExtensions: [String] = []
    /// Drop every extension instead of naming them.
    var stripExtensions = false
    var stripWatchApp = false
    var tweaks: [Tweak] = []
    /// The identity fields the user set themselves. The others always show —
    /// and apply — whatever the build being installed says, so importing another
    /// app never carries the last one's name and version along.
    var pinnedIdentity: [String] = []
    /// Bumped when the shape changes, so old saved configurations are ignored
    /// rather than decoded wrong.
    var schema = 3

    func isPinned(_ field: IdentityField) -> Bool {
        pinnedIdentity.contains(field.rawValue)
    }

    mutating func setPinned(_ field: IdentityField, _ pinned: Bool) {
        var set = Set(pinnedIdentity)
        if pinned { set.insert(field.rawValue) } else { set.remove(field.rawValue) }
        pinnedIdentity = Array(set).sorted()
    }

    /// The identity field's value, for the key path the editor writes through.
    subscript(field: IdentityField) -> String {
        get {
            switch field {
            case .bundleIdentifier: return bundleIdentifier
            case .displayName:      return displayName
            case .version:          return version
            case .build:            return build
            }
        }
        set {
            switch field {
            case .bundleIdentifier: bundleIdentifier = newValue
            case .displayName:      displayName = newValue
            case .version:          version = newValue
            case .build:            build = newValue
            }
        }
    }

    var isActive: Bool {
        !bundleIdentifier.trimmed.isEmpty || !displayName.trimmed.isEmpty
            || !version.trimmed.isEmpty || !build.trimmed.isEmpty
            || !plistEdits.isEmpty || !entitlements.isEmpty
            || !disabledExtensions.isEmpty || stripExtensions || stripWatchApp
            || !tweaks.isEmpty
    }

    /// One line per change, for the Install screen's summary.
    var summary: [String] {
        var out: [String] = []
        if !bundleIdentifier.trimmed.isEmpty { out.append(L("Bundle ID: %@", bundleIdentifier.trimmed)) }
        if !displayName.trimmed.isEmpty { out.append(L("Name: %@", displayName.trimmed)) }
        if !version.trimmed.isEmpty { out.append(L("Version: %@", version.trimmed)) }
        if !build.trimmed.isEmpty { out.append(L("Build: %@", build.trimmed)) }
        if !plistEdits.isEmpty { out.append(L("%d plist keys", plistEdits.count)) }
        if !entitlements.isEmpty { out.append(L("%d entitlements", entitlements.count)) }
        if stripExtensions { out.append(L("All extensions removed")) }
        if !disabledExtensions.isEmpty { out.append(L("%d extensions removed", disabledExtensions.count)) }
        if stripWatchApp { out.append(L("Watch app removed")) }
        for tweak in tweaks {
            out.append(tweak.isDeb ? L("Tweak (deb): %@", tweak.name) : L("Tweak: %@", tweak.name))
        }
        return out
    }

    /// The identity that will be registered as an App ID, when one was set.
    var resultingBundleIdentifier: String? {
        bundleIdentifier.trimmed.isEmpty ? nil : bundleIdentifier.trimmed
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The app-wide configuration, kept in Application Support next to the tweaks
/// and injector libraries it points at.
final class AppConfigStore: ObservableObject {

    static let shared = AppConfigStore()

    @Published var config: AppConfig {
        didSet { if config != oldValue { save() } }
    }
    /// Injector libraries the user added, one per framework.
    @Published private(set) var injectors: [TweakInjector] = []
    /// What a framework's download is doing, per kind: shown beside its row.
    @Published private(set) var injectorStatus: [TweakInjectorKind: String] = [:]

    private static let defaultsKey = "appConfig.v3"
    private static let injectorsKey = "appConfig.injectors.v1"

    private init() {
        config = Self.loadConfig()
        injectors = Self.loadInjectors()
        Self.forgetMissingFiles(in: &config, injectors: &injectors)
    }

    // MARK: - Files

    /// Where tweak and injector copies live, so a picked file that came from a
    /// temporary location survives until the next install.
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("AppConfig", isDirectory: true)
    }

    static var tweaksDirectory: URL { supportDirectory.appendingPathComponent("Tweaks", isDirectory: true) }
    static var injectorsDirectory: URL { supportDirectory.appendingPathComponent("Injectors", isDirectory: true) }

    private static func copy(_ url: URL, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    // MARK: - Tweaks

    /// Adds picked `.dylib` or `.deb` files. A `.deb` is read once here, so its
    /// package name and required injector can be shown before it's installed,
    /// and it replaces an earlier copy of the same package rather than sitting
    /// beside it: two builds of one tweak loaded together is never what anyone
    /// meant.
    ///
    /// `repository` is the repository a package came from, when the browser is
    /// the one adding it.
    @discardableResult
    func addTweaks(_ urls: [URL], repository: String? = nil) -> (added: Int, failed: [String]) {
        var added = 0
        var failed: [String] = []
        for url in urls {
            let name = url.lastPathComponent
            let lowered = name.lowercased()
            guard lowered.hasSuffix(".dylib") || lowered.hasSuffix(".deb") else {
                failed.append(name)
                continue
            }
            do {
                let stored = try Self.copy(url, into: Self.tweaksDirectory)
                if lowered.hasSuffix(".deb") {
                    let package = try DebArchive.read(stored)
                    // The package's own dependency first; failing that, what its
                    // libraries link against.
                    let linked = package.libraries.flatMap {
                        MachOInject.linkedLibraries(in: $0.data)
                    }
                    // The build it replaces, so its "load only if present"
                    // choice and its repository survive the swap.
                    let previous = package.identifier.flatMap { identifier in
                        config.tweaks.first { $0.identifier == identifier && $0.isDeb }
                    }
                    if let previous {
                        try? FileManager.default.removeItem(atPath: previous.path)
                        config.tweaks.removeAll { $0.id == previous.id }
                    }
                    config.tweaks.removeAll { $0.path == stored.path }
                    config.tweaks.append(Tweak(name: package.name ?? name,
                                               path: stored.path,
                                               kind: .deb,
                                               loadPath: "",
                                               weak: previous?.weak ?? false,
                                               requiresInjector: package.requiredInjector
                                                   ?? TweakInjectorKind.detected(inLibraries: linked),
                                               identifier: package.identifier,
                                               version: package.version,
                                               repository: repository ?? previous?.repository))
                } else {
                    // A bare library has no control file, so its links are the
                    // only clue to what it needs.
                    let linked = (try? Data(contentsOf: stored, options: .uncached))
                        .map { MachOInject.linkedLibraries(in: $0) } ?? []
                    config.tweaks.removeAll { $0.path == stored.path }
                    config.tweaks.append(Tweak(name: name, path: stored.path, kind: .dylib,
                                               loadPath: "@executable_path/Frameworks/\(name)",
                                               requiresInjector: TweakInjectorKind.detected(inLibraries: linked)))
                }
                added += 1
            } catch {
                failed.append(name)
            }
        }
        return (added, failed)
    }

    func isPinned(_ field: AppConfig.IdentityField) -> Bool { config.isPinned(field) }

    func pin(_ field: AppConfig.IdentityField, _ pinned: Bool) {
        config.setPinned(field, pinned)
    }

    func removeTweak(_ id: UUID) {
        guard let index = config.tweaks.firstIndex(where: { $0.id == id }) else { return }
        let tweak = config.tweaks.remove(at: index)
        try? FileManager.default.removeItem(atPath: tweak.path)
    }

    func setLoadPath(_ path: String, for id: UUID) {
        guard let index = config.tweaks.firstIndex(where: { $0.id == id }) else { return }
        config.tweaks[index].loadPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setWeak(_ weak: Bool, for id: UUID) {
        guard let index = config.tweaks.firstIndex(where: { $0.id == id }) else { return }
        config.tweaks[index].weak = weak
    }

    /// What a `.deb` carries, for the row's subtitle.
    func packageInfo(for tweak: Tweak) -> DebArchive.Package? {
        guard tweak.isDeb else { return nil }
        return try? DebArchive.read(URL(fileURLWithPath: tweak.path))
    }

    // MARK: - Injectors

    /// Adds the library that provides `kind`, replacing any previous one.
    @discardableResult
    func addInjector(_ kind: TweakInjectorKind, from url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "dylib",
              let stored = try? Self.copy(url, into: Self.injectorsDirectory)
        else { return false }
        injectors.removeAll { $0.kind == kind }
        injectors.append(TweakInjector(kind: kind, path: stored.path,
                                       fileName: stored.lastPathComponent))
        saveInjectors()
        return true
    }

    /// Fetches a framework from where it's published (see `InjectorCatalog`),
    /// with its progress and any failure shown on its row.
    func downloadInjector(_ kind: TweakInjectorKind) async {
        injectorStatus[kind] = L("Downloading…")
        do {
            let fetched = try await InjectorCatalog.fetch(kind)
            if addInjectorData(fetched.data, kind: kind, fileName: fetched.fileName) {
                injectorStatus[kind] = L("Added %@", fetched.fileName)
            } else {
                injectorStatus[kind] = L("Couldn't store it.")
            }
        } catch {
            injectorStatus[kind] = (error as? LocalizedError)?.errorDescription
                ?? L("Download failed.")
        }
    }

    /// Stores library bytes as the framework for `kind`.
    @discardableResult
    func addInjectorData(_ data: Data, kind: TweakInjectorKind, fileName: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: Self.injectorsDirectory,
                                                    withIntermediateDirectories: true)
            let destination = Self.injectorsDirectory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try data.write(to: destination, options: .atomic)
            injectors.removeAll { $0.kind == kind }
            injectors.append(TweakInjector(kind: kind, path: destination.path, fileName: fileName))
            saveInjectors()
            return true
        } catch {
            injectorStatus[kind] = L("Couldn't store it: %@", error.localizedDescription)
            return false
        }
    }

    /// Drops a framework's last download message when its row changes state.
    func clearInjectorStatus(_ kind: TweakInjectorKind) {
        injectorStatus[kind] = nil
    }

    func removeInjector(_ kind: TweakInjectorKind) {
        guard let index = injectors.firstIndex(where: { $0.kind == kind }) else { return }
        let injector = injectors.remove(at: index)
        try? FileManager.default.removeItem(atPath: injector.path)
        saveInjectors()
    }

    func injector(for kind: TweakInjectorKind) -> TweakInjector? {
        injectors.first { $0.kind == kind }
    }

    /// The injectors the configured tweaks need but that aren't here yet.
    var missingInjectors: [TweakInjectorKind] {
        let needed = Set(config.tweaks.compactMap { $0.requiresInjector })
        return needed.filter { injector(for: $0) == nil }.sorted { $0.title < $1.title }
    }

    // MARK: - Whole configuration

    /// The configuration as JSON, for keeping or sharing.
    func exportData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(config)
    }

    /// Replaces the configuration from a JSON file. Tweaks and injectors keep
    /// their paths, so an imported file only works for packages that are here.
    @discardableResult
    func importData(_ data: Data) -> Bool {
        guard let decoded = try? JSONDecoder().decode(AppConfig.self, from: data),
              decoded.schema == 3 else { return false }
        config = decoded
        Self.forgetMissingFiles(in: &config, injectors: &injectors)
        return true
    }

    func reset() {
        let tweaks = config.tweaks
        config = AppConfig()
        for tweak in tweaks { try? FileManager.default.removeItem(atPath: tweak.path) }
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private func saveInjectors() {
        guard let data = try? JSONEncoder().encode(injectors) else { return }
        UserDefaults.standard.set(data, forKey: Self.injectorsKey)
    }

    private static func loadConfig() -> AppConfig {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data),
              config.schema == 2
        else { return AppConfig() }
        return config
    }

    private static func loadInjectors() -> [TweakInjector] {
        guard let data = UserDefaults.standard.data(forKey: injectorsKey),
              let injectors = try? JSONDecoder().decode([TweakInjector].self, from: data)
        else { return [] }
        return injectors
    }

    /// A tweak or injector whose file has been deleted (by iOS, or by the user
    /// in Files) can't be used, so it's dropped rather than failing the install.
    private static func forgetMissingFiles(in config: inout AppConfig,
                                           injectors: inout [TweakInjector]) {
        config.tweaks.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        injectors.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
    }
}
