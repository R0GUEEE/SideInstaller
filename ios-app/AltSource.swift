import Combine
import Foundation

/// An AltStore-format source: the JSON that AltStore, SideStore, Feather and
/// every other source-based sideloader read. SideInstaller loads one to browse
/// the apps it lists and install any of them, signed with your Apple ID, the
/// same way it installs anything else.
///
/// The format has two shapes in the wild and both are accepted: v2 keeps every
/// app's releases under `versions`, while v1 repeats the newest release as
/// top-level `version` / `downloadURL` / `size`. Fields a source leaves out are
/// simply absent, so every property here is optional except the name.
struct AltSource: Decodable, Identifiable, Sendable {

    let name: String
    let identifier: String?
    let subtitle: String?
    let description: String?
    let iconURL: String?
    let headerURL: String?
    let website: String?
    let tintColor: String?
    let featuredApps: [String]?
    let apps: [AltApp]
    let news: [AltNews]?

    /// The apps that can be installed, sorted by name. Worked out once here
    /// rather than per view pass: a big source lists hundreds of apps, and the
    /// sort inside `body` was enough to stall the page.
    let installableApps: [AltApp]

    /// Where it was fetched from; `SourceStore` fills this in.
    var sourceURL: URL?

    var id: String { identifier ?? name }

    private enum CodingKeys: String, CodingKey {
        case name, identifier, subtitle, description, iconURL, headerURL, website,
             tintColor, featuredApps, apps, news
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name)) ?? "Untitled source"
        identifier = try? container.decodeIfPresent(String.self, forKey: .identifier)
        subtitle = try? container.decodeIfPresent(String.self, forKey: .subtitle)
        description = try? container.decodeIfPresent(String.self, forKey: .description)
        iconURL = try? container.decodeIfPresent(String.self, forKey: .iconURL)
        headerURL = try? container.decodeIfPresent(String.self, forKey: .headerURL)
        website = try? container.decodeIfPresent(String.self, forKey: .website)
        tintColor = try? container.decodeIfPresent(String.self, forKey: .tintColor)
        featuredApps = try? container.decodeIfPresent([String].self, forKey: .featuredApps)
        news = try? container.decodeIfPresent([AltNews].self, forKey: .news)
        // A source whose apps can't be read is an error worth showing, so this
        // one isn't swallowed like the rest.
        let decoded = (try? container.decodeIfPresent([AltApp].self, forKey: .apps)) .flatMap { $0 } ?? []
        apps = decoded
        installableApps = decoded
            .filter { !$0.releases.isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The icon as a URL, when the source gave something usable.
    var icon: URL? { URL(string: iconURL ?? "") }
}

/// One app in a source.
struct AltApp: Decodable, Identifiable, Sendable {

    let name: String
    let bundleIdentifier: String?
    let developerName: String?
    let subtitle: String?
    let localizedDescription: String?
    let iconURL: String?
    let tintColor: String?
    let category: String?
    let screenshots: [String]?
    let versions: [AltVersion]?

    /// v1 repeats the newest release at the app's top level.
    let version: String?
    let downloadURL: String?
    let size: Int64?

    /// Every release that can actually be downloaded, newest first. Worked out
    /// once at decode time: the list is read by list rows, the release picker
    /// and the source's own filtering, and re-deriving it each time was most of
    /// the cost of a big source.
    let releases: [AltVersion]

    var id: String { (bundleIdentifier ?? name) + "@" + (iconURL ?? "") }

    private enum CodingKeys: String, CodingKey {
        case name, bundleIdentifier, developerName, subtitle, localizedDescription,
             iconURL, tintColor, category, screenshots, versions,
             version, downloadURL, size
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name)) ?? "Untitled app"
        bundleIdentifier = try? container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        developerName = try? container.decodeIfPresent(String.self, forKey: .developerName)
        subtitle = try? container.decodeIfPresent(String.self, forKey: .subtitle)
        localizedDescription = try? container.decodeIfPresent(String.self, forKey: .localizedDescription)
        iconURL = try? container.decodeIfPresent(String.self, forKey: .iconURL)
        tintColor = try? container.decodeIfPresent(String.self, forKey: .tintColor)
        category = try? container.decodeIfPresent(String.self, forKey: .category)
        screenshots = try? container.decodeIfPresent([String].self, forKey: .screenshots)
        versions = try? container.decodeIfPresent([AltVersion].self, forKey: .versions)
        version = try? container.decodeIfPresent(String.self, forKey: .version)
        downloadURL = try? container.decodeIfPresent(String.self, forKey: .downloadURL)
        size = try? container.decodeIfPresent(Int64.self, forKey: .size)

        // A v1 source lists no `versions`, so its top-level release stands in.
        var found = (versions ?? []).filter { $0.url != nil }
        if found.isEmpty, let link = downloadURL,
           let url = URL(string: link), url.scheme?.hasPrefix("http") == true {
            found = [AltVersion(version: version, buildVersion: nil, date: nil,
                                localizedDescription: localizedDescription,
                                downloadURL: link, size: size, minOSVersion: nil)]
        }
        releases = Array(found.reversed())
    }

    var latest: AltVersion? { releases.first }

    var icon: URL? { URL(string: iconURL ?? "") }

    /// The screenshots as URLs, skipping anything that isn't one.
    var screenshotURLs: [URL] {
        (screenshots ?? []).compactMap { URL(string: $0) }
    }
}

/// One release of an app in a source.
struct AltVersion: Decodable, Identifiable, Equatable, Sendable {

    let version: String?
    let buildVersion: String?
    let date: String?
    let localizedDescription: String?
    let downloadURL: String?
    let size: Int64?
    let minOSVersion: String?

    var id: String { (version ?? "?") + "|" + (buildVersion ?? "") + "|" + (downloadURL ?? "") }

    /// The download, when it's a link that can be followed.
    var url: URL? {
        guard let downloadURL, let url = URL(string: downloadURL),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else { return nil }
        return url
    }

    /// The release date as published (ISO 8601 for v2 sources).
    var dateValue: Date? {
        guard let date else { return nil }
        return ISO8601DateFormatter().date(from: date) ?? Self.dayFormatter.date(from: date)
    }

    var sizeText: String? {
        guard let size, size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// True when this release says it needs a newer iOS than the one running.
    var needsNewerOS: Bool {
        guard let major = Int((minOSVersion ?? "").split(separator: ".").first ?? "") else { return false }
        return major > ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// One news item in a source (v2), shown at the top of its page.
struct AltNews: Decodable, Identifiable, Sendable {
    let title: String?
    let identifier: String?
    let caption: String?
    let date: String?
    let url: String?
    let appID: String?
    let tintColor: String?

    var id: String { identifier ?? title ?? UUID().uuidString }

    var link: URL? { URL(string: url ?? "") }
}

// MARK: - The marketplace's own records

/// One app as the marketplace lists it: the few fields a row shows, plus its
/// releases. Built from a source when its JSON is decoded, then thrown away —
/// the full document, with its descriptions, screenshots and news, is never
/// kept in memory.
struct MarketEntry: Identifiable, Sendable, Codable {

    /// One downloadable release.
    struct Version: Identifiable, Sendable, Codable, Equatable {
        /// The download URL doubles as the identity: it's what makes a release
        /// distinct across sources.
        let id: String
        let version: String?
        let date: Date?
        let size: Int64?
        /// Where it downloads from.
        let url: String
        let minOS: String?
        /// The source carrying it, so the page can name it and the row can
        /// filter by source.
        let sourceID: String
        let sourceName: String

        var link: URL? { URL(string: url) }

        var needsNewerOS: Bool {
            guard let major = Int((minOS ?? "").split(separator: ".").first ?? "") else { return false }
            return major > ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        }
    }

    /// The bundle ID, or the name for a source that doesn't give one.
    let id: String
    var name: String
    var developer: String?
    var subtitle: String?
    var icon: String?
    var category: String
    /// Newest first.
    var versions: [Version]

    var latest: Version? { versions.first }
    var iconURL: URL? { URL(string: icon ?? "") }
    var date: Date? { latest?.date }
    var size: Int64? { latest?.size }

    /// The release a chosen one picks out, or the newest.
    func release(_ chosen: Version?) -> Version? {
        guard let chosen else { return latest }
        return versions.first { $0.id == chosen.id } ?? latest
    }
}

extension MarketEntry {
    /// Turns one decoded source into its entries. Runs off the main actor; the
    /// source document itself isn't retained.
    static func entries(in source: AltSource) -> [MarketEntry] {
        let sourceID = source.sourceURL?.absoluteString ?? source.name
        var out: [MarketEntry] = []
        out.reserveCapacity(source.apps.count)
        for app in source.installableApps {
            var seen = Set<String>()
            var versions: [MarketEntry.Version] = []
            for release in app.releases {                     // already newest first
                guard let url = release.url?.absoluteString, seen.insert(url).inserted else { continue }
                versions.append(.init(id: url,
                                      version: release.version,
                                      date: release.dateValue,
                                      size: release.size,
                                      url: url,
                                      minOS: release.minOSVersion,
                                      sourceID: sourceID,
                                      sourceName: source.name))
            }
            guard !versions.isEmpty else { continue }
            out.append(MarketEntry(id: app.bundleIdentifier ?? app.name,
                                   name: app.name,
                                   developer: app.developerName,
                                   subtitle: app.subtitle,
                                   icon: app.iconURL,
                                   category: app.category ?? "",
                                   versions: versions))
        }
        return out
    }
}

// MARK: - Loading and keeping sources

/// The sources the user added, fetched and cached.
///
/// Fetching is parallel and conditional (an `If-None-Match` on the cached copy
/// usually answers 304, so a refresh costs nothing), the JSON is decoded off the
/// main actor, and what's kept is `MarketEntry` records rather than the
/// documents — a source with ten thousand apps is millions of bytes of JSON and
/// a few hundred kilobytes of rows.
final class SourceStore: ObservableObject {

    /// One source as the list shows it.
    struct Loaded: Identifiable {
        let url: URL
        var name = ""
        var icon: URL?
        var appCount = 0
        var error: String?
        var fetched: Date?
        var isLoading = false
        /// What arrived last time, so a failed refresh can still be browsed.
        var isStale = false
        /// The apps this source marks as featured.
        var featured: Set<String> = []
        /// What it was recognised as (AltStore JSON, GitHub releases) and which
        /// store it came from.
        var origin = SourceOrigin(kind: .altSource, store: SourceKind.Store.other.rawValue)

        var id: String { url.absoluteString }
        /// True once anything is known about it.
        var hasIndex: Bool { appCount > 0 || fetched != nil }
    }

    @Published private(set) var sources: [Loaded] = []
    /// Every app from every source, one entry per bundle ID with all of its
    /// releases merged. This is what the marketplace draws.
    @Published private(set) var entries: [MarketEntry] = []
    /// Bumped whenever `entries` changes, so views can memoise their lists.
    @Published private(set) var revision = 0
    /// The apps the sources mark as featured, by bundle ID.
    @Published private(set) var featuredKeys: Set<String> = []
    /// Set while an add is downloading and decoding, so the field can show it.
    @Published private(set) var isAdding = false

    private static let defaultsKey = "altsource.urls"
    private let defaults = UserDefaults.standard
    /// One file per source, keyed by the URL's hash so any path is a safe name.
    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Sources", isDirectory: true)
    }
    /// The index each source produced, kept so a merge doesn't need the JSON.
    private var indexBySource: [String: [MarketEntry]] = [:]

    /// Sources offered before the user has added any.
    static let starterSources = ["https://apps.altstore.io"]

    // MARK: - Loading

    func load() {
        guard sources.isEmpty else { return }
        let saved = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        let links = saved.isEmpty ? Self.starterSources : saved
        sources = links.compactMap(URL.init(string:)).map { Loaded(url: $0) }
        Task {
            // Cached copies first: the marketplace is browsable before the
            // network answers, and a 304 leaves this as the final state.
            await withTaskGroup(of: (String, (source: AltSource, date: Date)?).self) { group in
                for loaded in sources {
                    let id = loaded.id
                    let url = loaded.url
                    group.addTask {
                        (id, await Task.detached(priority: .userInitiated) {
                            SourceStore.cachedSource(for: url)
                        }.value)
                    }
                }
                for await (id, cached) in group {
                    guard let cached, let index = sources.firstIndex(where: { $0.id == id }) else { continue }
                    sources[index].name = cached.source.name
                    sources[index].icon = cached.source.icon
                    sources[index].fetched = cached.date
                    sources[index].isStale = true
                    sources[index].featured = Set(cached.source.featuredApps ?? [])
                    let entries = await Task.detached(priority: .userInitiated) {
                        MarketEntry.entries(in: cached.source)
                    }.value
                    indexBySource[id] = entries
                    sources[index].appCount = entries.count
                }
            }
            merge()
            await refreshAll(force: false)
        }
    }

    /// Fetches every source at once, a few at a time. `force` re-downloads one
    /// that already loaded.
    func refreshAll(force: Bool = true) async {
        let wanted = sources.filter { force || $0.fetched == nil }.map(\.id)
        guard !wanted.isEmpty else { return }
        // Four at a time: sources are independent hosts and most of the wait is
        // the network, not the decoding.
        await withTaskGroup(of: Void.self) { group in
            var pending = wanted[...]
            func addNext() {
                guard let id = pending.popFirst() else { return }
                group.addTask { await self.refresh(id) }
            }
            for _ in 0..<4 { addNext() }
            for await _ in group { addNext() }
        }
        merge()
    }

    func refresh(_ id: String) async {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].isLoading = true
        defer { if let still = sources.firstIndex(where: { $0.id == id }) { sources[still].isLoading = false } }
        let url = sources[index].url
        let origin = sources[index].origin
        do {
            if origin.kind == .github, let parts = GitHubSource.repo(from: url) {
                let name = sources[index].name
                let entries = try await GitHubSource.entries(owner: parts.owner, repo: parts.repo,
                                                             sourceName: name)
                guard let at = sources.firstIndex(where: { $0.id == id }) else { return }
                sources[at].error = nil
                sources[at].fetched = Date()
                indexBySource[id] = entries
                sources[at].appCount = entries.count
                return
            }
            let fetched = try await Self.fetch(url)
            guard let still = sources.firstIndex(where: { $0.id == id }) else { return }
            sources[still].name = fetched.source.name
            sources[still].icon = fetched.source.icon
            sources[still].error = nil
            sources[still].isStale = fetched.isCached
            sources[still].featured = Set(fetched.source.featuredApps ?? [])
            if !fetched.isCached { sources[still].fetched = Date() }
            let entries = await Task.detached(priority: .userInitiated) {
                MarketEntry.entries(in: fetched.source)
            }.value
            indexBySource[id] = entries
            sources[still].appCount = entries.count
        } catch {
            guard let still = sources.firstIndex(where: { $0.id == id }) else { return }
            sources[still].error = Self.message(for: error)
        }
    }

    /// Merges every source's index into one list: one entry per bundle ID, its
    /// releases from all of them, each tagged with the source that carries it.
    private func merge() {
        var merged: [String: MarketEntry] = [:]
        var capacity = 0
        for entries in indexBySource.values { capacity += entries.count }
        merged.reserveCapacity(capacity)

        for id in sources.map(\.id) {
            guard let entries = indexBySource[id] else { continue }
            for entry in entries {
                guard var existing = merged[entry.id] else {
                    merged[entry.id] = entry
                    continue
                }
                // Union of releases, newest first, one per download URL.
                var seen = Set(existing.versions.map(\.id))
                for version in entry.versions where seen.insert(version.id).inserted {
                    existing.versions.append(version)
                }
                existing.versions.sort { lhs, rhs in
                    let left = lhs.date ?? .distantPast
                    let right = rhs.date ?? .distantPast
                    if left != right { return left > right }
                    return (lhs.version ?? "").compare(rhs.version ?? "", options: .numeric) == .orderedDescending
                }
                // The entry's own name and icon come from whichever source has
                // the newest release.
                if (entry.latest?.date ?? .distantPast) > (existing.latest?.date ?? .distantPast) {
                    existing.name = entry.name
                    existing.developer = entry.developer ?? existing.developer
                    existing.subtitle = entry.subtitle ?? existing.subtitle
                    existing.icon = entry.icon ?? existing.icon
                }
                merged[entry.id] = existing
            }
        }
        entries = merged.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        featuredKeys = sources.reduce(into: Set<String>()) { $0.formUnion($1.featured) }
        revision += 1
    }

    /// How many apps a source contributes, for its rail row.
    func count(for id: String) -> Int {
        indexBySource[id]?.count ?? 0
    }

    // MARK: - Adding and removing

    /// Adds the source at `text` (a pasted link, or an `altstore://source?url=`
    /// link someone shared). Returns nil on success, or why it couldn't be added.
    @discardableResult
    func add(_ text: String, origin: SourceOrigin? = nil) async -> String? {
        guard !isAdding else { return nil }
        guard let url = Self.sourceURL(from: text) else {
            return L("That isn't a link to a source. Paste the whole https:// address of the source's JSON file.")
        }
        let detected = origin ?? SourceOrigin.detect(text)
        if sources.contains(where: { $0.url.absoluteString == url.absoluteString }) {
            return L("%@ is already in the list.", url.host ?? url.absoluteString)
        }
        isAdding = true
        defer { isAdding = false }
        do {
            var loaded = Loaded(url: url)
            loaded.origin = detected
            var entries: [MarketEntry] = []
            switch detected.kind {
            case .altSource:
                let fetched = try await Self.fetch(url)
                loaded.name = fetched.source.name
                loaded.icon = fetched.source.icon
                loaded.fetched = Date()
                loaded.featured = Set(fetched.source.featuredApps ?? [])
                entries = await Task.detached(priority: .userInitiated) {
                    MarketEntry.entries(in: fetched.source)
                }.value
            case .github:
                guard let parts = GitHubSource.repo(from: url) else {
                    return L("That isn't a GitHub repository link. It should look like github.com/owner/repo.")
                }
                loaded.name = "\(parts.owner)/\(parts.repo)"
                entries = try await GitHubSource.entries(owner: parts.owner, repo: parts.repo,
                                                         sourceName: loaded.name)
                loaded.icon = URL(string: "https://github.com/\(parts.owner).png?size=120")
                loaded.fetched = Date()
            }
            sources.append(loaded)
            indexBySource[loaded.id] = entries
            if let index = sources.firstIndex(where: { $0.id == loaded.id }) {
                sources[index].appCount = entries.count
            }
            saveURLs()
            merge()
            return nil
        } catch {
            return Self.message(for: error)
        }
    }

    func remove(_ id: String) {
        sources.removeAll { $0.id == id }
        indexBySource[id] = nil
        saveURLs()
        merge()
    }

    private func saveURLs() {
        defaults.set(sources.map { $0.url.absoluteString }, forKey: Self.defaultsKey)
    }

    // MARK: Links

    /// Turns pasted text into a source URL: adds `https://` when there's no
    /// scheme, and accepts an `altstore://source?url=` link as-is.
    nonisolated static func sourceURL(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URLComponents(string: trimmed),
           ["altstore", "sidestore", "sideinstaller"].contains(url.scheme?.lowercased() ?? ""),
           let inner = url.queryItems?.first(where: { $0.name.lowercased() == "url" })?.value {
            trimmed = inner
        }
        let lowered = trimmed.lowercased()
        let hadScheme = lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
        if !hadScheme {
            guard !trimmed.contains("://") else { return nil }
            trimmed = "https://" + trimmed
        }
        guard let url = URL(string: trimmed), let host = url.host, host.contains(".") else { return nil }
        return url
    }

    // MARK: Fetching

    /// A source's JSON, from the cache when the server says it hasn't changed.
    ///
    /// The cached copy carries its `ETag`, which goes back as `If-None-Match`:
    /// most source hosts answer 304, so a refresh reads no body at all.
    struct Fetched {
        let source: AltSource
        let isCached: Bool
    }

    nonisolated static func fetch(_ url: URL) async throws -> Fetched {
        let cached = cachedSource(for: url)
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag = cachedEtag(for: url) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 304, let cached {
            return Fetched(source: cached.source, isCached: true)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SourceError.status(http.statusCode)
        }
        guard data.count < 24 << 20 else { throw SourceError.tooLarge }
        guard let source = await Task.detached(priority: .userInitiated,
                                               operation: { SourceStore.decode(data) }).value
        else { throw SourceError.notASource }
        guard !source.apps.isEmpty else { throw SourceError.noApps }
        var linked = source
        linked.sourceURL = url
        cache(data, etag: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"), for: url)
        return Fetched(source: linked, isCached: false)
    }

    /// One source's worth of JSON, however it arrived.
    nonisolated static func decode(_ data: Data) -> AltSource? {
        try? JSONDecoder().decode(AltSource.self, from: data)
    }

    enum SourceError: LocalizedError {
        case status(Int)
        case tooLarge
        case noApps
        case notASource

        var errorDescription: String? {
            switch self {
            case .status(let code):
                return L("The server answered %ld. The link may have moved.", code)
            case .tooLarge:
                return L("That file is too big to be a source.")
            case .noApps:
                return L("That source lists no apps.")
            case .notASource:
                return L("That isn't an AltStore source. It has to be the source's JSON file, not a page that links to it.")
            }
        }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? SourceError {
            return error.errorDescription ?? L("Couldn't load that source.")
        }
        if (error as NSError).domain == NSURLErrorDomain {
            return L("Couldn't reach that source: %@", error.localizedDescription)
        }
        return L("Couldn't load that source: %@", error.localizedDescription)
    }

    // MARK: Cache

    nonisolated private static func cacheFile(for url: URL) -> URL {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325      // FNV-1a
        for byte in Data(url.absoluteString.utf8) {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return cacheDirectory.appendingPathComponent(String(hash, radix: 16) + ".json")
    }

    nonisolated private static func cache(_ raw: Data, etag: String?, for url: URL) {
        guard let data = try? JSONEncoder().encode(CachedSource(raw: raw, date: Date(), etag: etag)) else { return }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: cacheFile(for: url), options: .atomic)
    }

    nonisolated private static func cachedSource(for url: URL) -> (source: AltSource, date: Date)? {
        guard let data = try? Data(contentsOf: cacheFile(for: url)),
              let cached = try? JSONDecoder().decode(CachedSource.self, from: data),
              let source = decode(cached.raw)
        else { return nil }
        return (source, cached.date)
    }

    nonisolated private static func cachedEtag(for url: URL) -> String? {
        guard let data = try? Data(contentsOf: cacheFile(for: url)),
              let cached = try? JSONDecoder().decode(CachedSource.self, from: data)
        else { return nil }
        return cached.etag
    }

    /// What's kept on disk: the source's JSON, when it arrived, and its ETag.
    private struct CachedSource: Codable {
        let raw: Data
        let date: Date
        let etag: String?
    }
}
