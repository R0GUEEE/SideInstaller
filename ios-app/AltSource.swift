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
struct AltSource: Identifiable, Sendable {

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

    /// Built from the document's bytes: leniently, field by field.
    init(data: Data) {
        // Read through `Any` rather than a typed schema: sources in the wild put
        // numbers where strings go (a `version` of `1`), and one mistyped field
        // used to cost the whole document — every app in a v1 source vanished
        // because its top-level `version` failed to decode as a string.
        let raw = JSONValue.object(data)
        let reader = PlistValue(raw)
        name = reader.string("name") ?? "Untitled source"
        identifier = reader.string("identifier")
        subtitle = reader.string("subtitle")
        description = reader.string("description")
        iconURL = reader.string("iconURL")
        headerURL = reader.string("headerURL")
        website = reader.string("website")
        tintColor = reader.string("tintColor")
        featuredApps = reader.strings("featuredApps")
        news = (raw["news"] as? [Any])?.compactMap { item -> AltNews? in
            guard let dict = item as? [String: Any] else { return nil }
            return AltNews(plist: dict)
        }
        let decodedApps = (raw["apps"] as? [Any])?.compactMap { item -> AltApp? in
            guard let dict = item as? [String: Any] else { return nil }
            return AltApp(plist: dict)
        } ?? []
        apps = decodedApps
        installableApps = decodedApps
            .filter { !$0.releases.isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The icon as a URL, when the source gave something usable.
    var icon: URL? { URL(string: iconURL ?? "") }
}

/// Turns a decoded JSON value back into Foundation objects, so a whole
/// document can be read field by field instead of through typed containers.
///
/// `JSONDecoder` offers no way to get the raw value of a key that isn't the
/// type it was asked for; this walks `[String: Any]` / `[Any]` / scalars
/// directly, which is the "parse, then interpret" model sources need.
enum JSONValue {
    /// The whole document as Foundation objects.
    ///
    /// `Decodable` can't hand back an untyped tree, and sources don't share one
    /// schema — one writes `"version": "1.2"`, the next `"version": 1`. So the
    /// bytes go through `JSONSerialization` once and every field is then
    /// checked by `PlistValue` when it's read.
    static func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

/// Reads plist-ish JSON leniently: a value that isn't the type asked for is
/// returned as nil instead of failing the whole document.
struct PlistValue {
    let raw: [String: Any]

    init(_ raw: [String: Any]) { self.raw = raw }

    func string(_ key: String) -> String? {
        switch raw[key] {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        case let flag as Bool: return flag ? "true" : "false"
        default: return nil
        }
    }

    func strings(_ key: String) -> [String]? {
        guard let list = raw[key] as? [Any] else { return nil }
        return list.compactMap {
            if let text = $0 as? String { return text }
            if let number = $0 as? NSNumber { return number.stringValue }
            return nil
        }
    }

    func int(_ key: String) -> Int64? {
        switch raw[key] {
        case let number as NSNumber: return number.int64Value
        case let text as String: return Int64(text)
        default: return nil
        }
    }
}

/// One app in a source.
struct AltApp: Identifiable, Sendable {

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

    /// Built from one app's JSON, leniently: a field of the wrong type is
    /// dropped, not the app.
    init(plist: [String: Any]) {
        let reader = PlistValue(plist)
        name = reader.string("name") ?? "Untitled app"
        bundleIdentifier = reader.string("bundleIdentifier")
        developerName = reader.string("developerName")
        subtitle = reader.string("subtitle")
        localizedDescription = reader.string("localizedDescription")
        iconURL = reader.string("iconURL")
        tintColor = reader.string("tintColor")
        category = reader.string("category")
        screenshots = reader.strings("screenshots")
        version = reader.string("version")
        downloadURL = reader.string("downloadURL")
        size = reader.int("size")

        let listed = (plist["versions"] as? [Any])?.compactMap { item -> AltVersion? in
            guard let dict = item as? [String: Any] else { return nil }
            return AltVersion(plist: dict)
        } ?? []
        versions = listed
        releases = AltApp.releases(from: listed,
                                   top: (version: version, downloadURL: downloadURL,
                                         size: size, description: localizedDescription),
                                   date: reader.string("versionDate"))
    }

    /// Newest first, downloadable only. A v1 app (no `versions`) keeps its own
    /// top-level release, which is where these sources put the only one they
    /// have — CyPwn's whole catalogue is shaped that way.
    static func releases(from listed: [AltVersion],
                         top: (version: String?, downloadURL: String?, size: Int64?, description: String?),
                         date: String?) -> [AltVersion] {
        var found = listed.filter { $0.url != nil }
        if found.isEmpty, let link = top.downloadURL,
           let url = URL(string: link), url.scheme?.hasPrefix("http") == true {
            found = [AltVersion(version: top.version, buildVersion: nil, date: date,
                                localizedDescription: top.description,
                                downloadURL: link, size: top.size, minOSVersion: nil)]
        }
        return Array(found.reversed())
    }

    var latest: AltVersion? { releases.first }

    var icon: URL? { URL(string: iconURL ?? "") }

    /// The screenshots as URLs, skipping anything that isn't one.
    var screenshotURLs: [URL] {
        (screenshots ?? []).compactMap { URL(string: $0) }
    }
}

/// One release of an app in a source.
struct AltVersion: Identifiable, Equatable, Sendable {

    let version: String?
    let buildVersion: String?
    let date: String?
    let localizedDescription: String?
    let downloadURL: String?
    let size: Int64?
    let minOSVersion: String?

    /// The memberwise initialiser Swift would have generated, kept so the
    /// v1 fallback can build a release from an app's own fields.
    init(version: String?, buildVersion: String?, date: String?,
         localizedDescription: String?, downloadURL: String?, size: Int64?,
         minOSVersion: String?) {
        self.version = version
        self.buildVersion = buildVersion
        self.date = date
        self.localizedDescription = localizedDescription
        self.downloadURL = downloadURL
        self.size = size
        self.minOSVersion = minOSVersion
    }

    init(plist: [String: Any]) {
        let reader = PlistValue(plist)
        version = reader.string("version")
        buildVersion = reader.string("buildVersion")
        date = reader.string("date") ?? reader.string("versionDate")
        localizedDescription = reader.string("localizedDescription")
        downloadURL = reader.string("downloadURL")
        size = reader.int("size")
        minOSVersion = reader.string("minOSVersion")
    }

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
struct AltNews: Identifiable, Sendable {
    let title: String?
    let identifier: String?
    let caption: String?
    let date: String?
    let url: String?
    let appID: String?
    let tintColor: String?

    init(plist: [String: Any]) {
        let reader = PlistValue(plist)
        title = reader.string("title")
        identifier = reader.string("identifier")
        caption = reader.string("caption")
        date = reader.string("date")
        url = reader.string("url")
        appID = reader.string("appID")
        tintColor = reader.string("tintColor")
    }

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
