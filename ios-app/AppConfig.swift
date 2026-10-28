import Combine
import Foundation

/// What to change about a custom `.ipa` on the way to being signed: its
/// identity, its nested bundles, and the tweaks loaded into it.
///
/// Everything here is optional and empty by default — an untouched
/// configuration leaves the archive exactly as imported.
struct AppConfig: Codable, Equatable {

    /// A tweak to load into the app's main executable.
    struct Tweak: Codable, Identifiable, Equatable {
        var id = UUID()
        /// File name, e.g. `MyTweak.dylib`.
        var name: String
        /// Where the library was copied to, in Application Support.
        var path: String
        /// What the executable loads, e.g. `@executable_path/Frameworks/MyTweak.dylib`.
        var loadPath: String
        /// Load it if it's there rather than requiring it (`LC_LOAD_WEAK_DYLIB`).
        var weak = false
    }

    /// New `CFBundleIdentifier`. Extensions and watch apps are re-prefixed to
    /// match, which is what makes a second copy of an app installable.
    var bundleIdentifier = ""
    /// New `CFBundleDisplayName` and `CFBundleName`.
    var displayName = ""
    /// New `CFBundleShortVersionString`.
    var version = ""
    /// New `CFBundleVersion`.
    var build = ""
    /// Drop `PlugIns/` from the app, so no extension is registered or signed.
    var stripExtensions = false
    /// Drop the embedded watch app.
    var stripWatchApp = false
    /// Libraries to inject into the main executable and add to `Frameworks/`.
    var tweaks: [Tweak] = []

    /// True when applying it would change anything at all.
    var isActive: Bool {
        !bundleIdentifier.trimmed.isEmpty || !displayName.trimmed.isEmpty
            || !version.trimmed.isEmpty || !build.trimmed.isEmpty
            || stripExtensions || stripWatchApp || !tweaks.isEmpty
    }

    /// One line per change, for the Install screen's summary.
    var summary: [String] {
        var out: [String] = []
        if !bundleIdentifier.trimmed.isEmpty { out.append(L("Bundle ID: %@", bundleIdentifier.trimmed)) }
        if !displayName.trimmed.isEmpty { out.append(L("Name: %@", displayName.trimmed)) }
        if !version.trimmed.isEmpty { out.append(L("Version: %@", version.trimmed)) }
        if !build.trimmed.isEmpty { out.append(L("Build: %@", build.trimmed)) }
        if stripExtensions { out.append(L("Extensions removed")) }
        if stripWatchApp { out.append(L("Watch app removed")) }
        for tweak in tweaks {
            out.append(tweak.weak ? L("Tweak (weak): %@", tweak.name) : L("Tweak: %@", tweak.name))
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
/// it points at.
///
/// A shared instance rather than an injected object: the Install screen edits
/// it and `Engine` reads it mid-run, from a task that isn't a view.
///
/// Not actor-isolated, like the other managers here: everything that touches it
/// runs on the main thread already, and `Engine` reads it from a `@MainActor`
/// step.
final class AppConfigStore: ObservableObject {

    static let shared = AppConfigStore()

    @Published var config: AppConfig {
        didSet { if config != oldValue { save() } }
    }

    private static let defaultsKey = "appConfig.v1"

    private init() {
        config = Self.load()
        Self.removeMissingTweaks(from: &config)
    }

    // MARK: Tweaks

    /// Where tweak copies live, so a picked file that came from a temporary
    /// location survives until the next install.
    private static var tweaksDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("AppConfig/Tweaks", isDirectory: true)
    }

    /// Copies picked `.dylib` files in and adds them to the list. Returns how
    /// many were added and what couldn't be read.
    @discardableResult
    func addTweaks(_ urls: [URL]) -> (added: Int, failed: [String]) {
        var added = 0
        var failed: [String] = []
        try? FileManager.default.createDirectory(at: Self.tweaksDirectory,
                                                 withIntermediateDirectories: true)
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent
            guard name.lowercased().hasSuffix(".dylib") else {
                failed.append(name)
                continue
            }
            let destination = Self.tweaksDirectory.appendingPathComponent(name)
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
                // A dylib already listed by that name is replaced, not doubled.
                config.tweaks.removeAll { $0.name == name }
                config.tweaks.append(AppConfig.Tweak(name: name, path: destination.path,
                                                     loadPath: "@executable_path/Frameworks/\(name)"))
                added += 1
            } catch {
                failed.append(name)
            }
        }
        return (added, failed)
    }

    func removeTweak(_ id: UUID) {
        guard let index = config.tweaks.firstIndex(where: { $0.id == id }) else { return }
        let tweak = config.tweaks.remove(at: index)
        // The copy is the app's own, so removing it is safe.
        try? FileManager.default.removeItem(atPath: tweak.path)
    }

    func setWeak(_ weak: Bool, for id: UUID) {
        guard let index = config.tweaks.firstIndex(where: { $0.id == id }) else { return }
        config.tweaks[index].weak = weak
    }

    func reset() {
        let tweaks = config.tweaks
        config = AppConfig()
        for tweak in tweaks { try? FileManager.default.removeItem(atPath: tweak.path) }
    }

    // MARK: Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private static func load() -> AppConfig {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data)
        else { return AppConfig() }
        return config
    }

    /// A tweak whose file has been deleted (by iOS, or by the user in Files)
    /// can't be injected, so it's dropped rather than failing the install.
    private static func removeMissingTweaks(from config: inout AppConfig) {
        config.tweaks.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
    }
}
