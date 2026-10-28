import Foundation

/// The kinds of repository SideInstaller can read.
///
/// One format is universal — the AltStore/SideStore JSON catalogue — and every
/// store that publishes a source uses it, so most of this is labelling: the
/// same parser, told which store the link came from so the UI can say "E-Sign"
/// rather than "source", and so a bare link can be recognised as a GitHub
/// release feed and read without one.
enum SourceKind: String, CaseIterable, Identifiable, Codable, Sendable {
    /// An AltStore-format JSON catalogue (the format Feather, SideStore, E-Sign
    /// and the rest all publish).
    case altSource
    /// A GitHub repository whose releases carry `.ipa` assets.
    case github

    var id: String { rawValue }

    var title: String {
        switch self {
        case .altSource: return L("AltStore source")
        case .github:    return L("GitHub releases")
        }
    }

    /// The stores whose links people paste. Not a limit — any host works — just
    /// the ones worth recognising, so a link opens with a sensible label and the
    /// right hint in the add sheet.
    enum Store: String, CaseIterable, Identifiable {
        case altStore, sideStore, eSign, feather, scarlet, esignHub, other

        var id: String { rawValue }

        var title: String {
            switch self {
            case .altStore:  return "AltStore"
            case .sideStore: return "SideStore"
            case .eSign:     return "E-Sign"
            case .feather:   return "Feather"
            case .scarlet:   return "Scarlet"
            case .esignHub:  return "E-Sign Hub"
            case .other:     return L("Other")
            }
        }

        /// The scheme its own `…://source?url=` links use, when it has one.
        var schemes: [String] {
            switch self {
            case .altStore:  return ["altstore"]
            case .sideStore: return ["sidestore"]
            case .eSign:     return ["esign", "esignplus"]
            case .feather:   return ["feather"]
            case .scarlet:   return ["scarlet"]
            default:         return []
            }
        }

        /// Hosts that belong to the store itself (not the many community
        /// repositories that publish AltStore-format JSON).
        var hosts: [String] {
            switch self {
            case .altStore:  return ["altstore.io"]
            case .sideStore: return ["sidestore.io", "sidestore.github.io"]
            case .eSign:     return ["esign.yyyue.xyz", "esign.flycoding.cn"]
            case .feather:   return ["feather.ioshaven.com"]
            case .scarlet:   return ["scarlet.ioshaven.com"]
            case .esignHub:  return ["esignhub.dev"]
            case .other:     return []
            }
        }

        static func of(host: String?) -> Store {
            guard let host = host?.lowercased() else { return .other }
            for store in allCases {
                if store.hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                    return store
                }
            }
            return .other
        }
    }
}

/// What a source was recognised as when it was added.
struct SourceOrigin: Codable, Sendable, Equatable {
    var kind: SourceKind
    /// The store it came from, when one was recognised.
    var store: String

    var storeName: String { SourceKind.Store(rawValue: store)?.title ?? SourceKind.Store.other.title }

    /// Reads a link before it's fetched: its scheme names a store, and so does
    /// the `altstore://source?url=` style wrapper.
    static func detect(_ text: String) -> SourceOrigin {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed),
           let scheme = components.scheme?.lowercased(),
           let store = SourceKind.Store.allCases.first(where: { $0.schemes.contains(scheme) }) {
            return SourceOrigin(kind: .altSource, store: store.rawValue)
        }
        let host = URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed)?.host
        let store = SourceKind.Store.of(host: host)
        if isGitHubReleaseFeed(host) {
            return SourceOrigin(kind: .github, store: SourceKind.Store.other.rawValue)
        }
        return SourceOrigin(kind: .altSource, store: store.rawValue)
    }

    /// `github.com/<owner>/<repo>` — a repository, not a file in one.
    static func isGitHubReleaseFeed(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "github.com" || host == "www.github.com"
    }
}

// MARK: - GitHub releases as a source

/// A GitHub repository read as a source: every `.ipa` on its releases, newest
/// first, becomes an app.
///
/// Some IPAs get their own app each (different bundle IDs); one repository that
/// keeps re-releasing the same app becomes one app with one release per tag.
enum GitHubSource {

    struct Release {
        let tag: String
        let name: String?
        let published: Date?
        let body: String?
        let assets: [(name: String, url: URL, size: Int64, date: Date?)]
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Reads `owner/repo` from a github.com link.
    static func repo(from url: URL) -> (owner: String, repo: String)? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        var owner = parts[0]
        var repo = parts[1]
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        if owner == "www" { owner = parts[0] }
        return (owner, repo)
    }

    /// Fetches the releases and turns their `.ipa` assets into market entries.
    static func entries(owner: String, repo: String, sourceName: String) async throws -> [MarketEntry] {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=30")!)
        request.timeoutInterval = 25
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SideInstaller", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 403 || http.statusCode == 429 {
                throw Failure(message: L("GitHub is rate-limiting this iPhone. Try again in a few minutes, or add the repository as an AltStore source instead."))
            }
            guard (200...299).contains(http.statusCode) else {
                throw Failure(message: L("GitHub answered %ld for %@/%@.", http.statusCode, owner, repo))
            }
        }
        guard let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !releases.isEmpty else {
            throw Failure(message: L("%@/%@ has no releases.", owner, repo))
        }

        let formatter = ISO8601DateFormatter()
        let sourceID = "github:\(owner)/\(repo)"
        var byApp: [String: MarketEntry] = [:]
        var order: [String] = []

        for raw in releases {
            guard let tag = raw["tag_name"] as? String else { continue }
            let published = (raw["published_at"] as? String ?? raw["created_at"] as? String)
                .flatMap { formatter.date(from: $0) }
            let body = raw["body"] as? String
            let assets = (raw["assets"] as? [[String: Any]] ?? []).compactMap { asset -> (String, URL, Int64, Date?)? in
                guard let name = asset["name"] as? String, name.lowercased().hasSuffix(".ipa"),
                      let link = asset["browser_download_url"] as? String, let url = URL(string: link)
                else { return nil }
                let updated = (asset["updated_at"] as? String).flatMap { formatter.date(from: $0) }
                return (name, url, Int64(asset["size"] as? Int ?? 0), updated)
            }
            guard let asset = assets.first else { continue }

            // The asset's own name is the only identity a release feed has.
            let stem = (asset.0 as NSString).deletingPathExtension
            let key = stem.lowercased()
            let version = MarketEntry.Version(id: asset.1.absoluteString,
                                              version: tag,
                                              date: published ?? asset.3,
                                              size: asset.2,
                                              url: asset.1.absoluteString,
                                              minOS: nil,
                                              sourceID: sourceID,
                                              sourceName: sourceName)
            if var existing = byApp[key] {
                existing.versions.append(version)
                existing.versions.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
                byApp[key] = existing
            } else {
                byApp[key] = MarketEntry(id: "\(sourceID)#\(key)",
                                         name: stem,
                                         developer: owner,
                                         subtitle: body?.split(separator: "\n").first.map(String.init),
                                         icon: "https://github.com/\(owner).png?size=120",
                                         category: "",
                                         versions: [version])
                order.append(key)
            }
        }
        guard !byApp.isEmpty else {
            throw Failure(message: L("%@/%@ has no releases with an .ipa.", owner, repo))
        }
        return order.compactMap { byApp[$0] }
    }
}
