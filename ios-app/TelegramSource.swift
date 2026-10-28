import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A Telegram channel as a source: the `.ipa` files its posts carry.
///
/// Telegram has no public API for reading a channel without an account, but it
/// does publish an HTML preview at `t.me/s/<channel>` — the same page a browser
/// shows. That's what this reads. It gives the document's name and size, and the
/// post's permalink, but **not** a download URL: file links are minted per
/// session by the Telegram client and expire.
///
/// So a Telegram entry is honest about what it is: a listing you can browse
/// beside your other sources, whose install button opens the post in Telegram to
/// download — unless the post itself links a direct `.ipa`, in which case that
/// link is used and the app installs normally.
enum TelegramSource {

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The channel name in a `t.me/<channel>` or `t.me/s/<channel>` link.
    static func channel(from url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        switch url.host?.lowercased() {
        case "t.me", "telegram.me", "www.t.me":
            let name = parts.first == "s" ? parts.dropFirst().first : parts.first
            guard let name, !name.isEmpty, name != "joinchat", name != "addstickers" else { return nil }
            return name
        default:
            return nil
        }
    }

    /// Reads the channel's public preview and turns its `.ipa` documents into
    /// entries.
    static func entries(channel: String) async throws -> (name: String, entries: [MarketEntry]) {
        var request = URLRequest(url: URL(string: "https://t.me/s/\(channel)")!)
        request.timeoutInterval = 25
        // The preview varies by user agent; a desktop browser gets the rich one.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                         + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 {
                throw Failure(message: L("Telegram has no public channel called @%@. Check the link, and that the channel isn't private.", channel))
            }
            guard (200...299).contains(http.statusCode) else {
                throw Failure(message: L("Telegram answered %ld for @%@.", http.statusCode, channel))
            }
        }
        guard data.count < 8 << 20 else {
            throw Failure(message: L("That channel's preview is unexpectedly large."))
        }
        let html = String(decoding: data, as: UTF8.self)
        guard html.contains("tgme_widget_message") else {
            throw Failure(message: L("Telegram didn't return a channel preview for @%@. It may be private, or have previews off.", channel))
        }

        let title = firstMatch(#"<meta property="og:title" content="([^"]+)""#, in: html)
            ?? "@\(channel)"
        var entries: [MarketEntry] = []
        var seen = Set<String>()

        for post in posts(in: html) {
            // A post's own links win: a direct .ipa downloads here, the rest
            // open in Telegram.
            let direct = post.links.first { $0.pathExtension.lowercased() == "ipa" }
            let permalink = URL(string: "https://t.me/\(channel)/\(post.id)")!

            var documents = post.documents
            if documents.isEmpty, let direct {
                // No attachment shown, but the text links an .ipa: list it.
                documents = [(name: direct.lastPathComponent, size: nil as Int64?,
                              sizeText: nil as String?)]
            }
            for document in documents {
                let name = displayName(document.name)
                guard seen.insert("\(post.id)|\(name)").inserted else { continue }
                var versions: [MarketEntry.Version] = []
                if let direct {
                    versions.append(.init(id: direct.absoluteString,
                                          version: version(in: document.name) ?? version(in: post.text),
                                          date: post.date,
                                          size: document.size ?? byteCount(document.sizeText),
                                          url: direct.absoluteString,
                                          minOS: nil,
                                          sourceID: "telegram:\(channel)",
                                          sourceName: title,
                                          direct: true))
                }
                // The Telegram route is always offered: it's the only way to
                // get a file the preview doesn't link.
                versions.append(.init(id: "tg://\(channel)/\(post.id)/\(name)",
                                      version: version(in: document.name) ?? version(in: post.text),
                                      date: post.date,
                                      size: document.size ?? byteCount(document.sizeText),
                                      url: permalink.absoluteString,
                                      minOS: nil,
                                      sourceID: "telegram:\(channel)",
                                      sourceName: title,
                                      direct: false))
                entries.append(MarketEntry(id: "telegram:\(channel):\(post.id):\(name.lowercased())",
                                           name: name,
                                           developer: "@\(channel)",
                                           subtitle: post.text?.split(separator: "\n").first.map(String.init),
                                           icon: nil,
                                           category: "Telegram",
                                           versions: versions))
            }
        }

        guard !entries.isEmpty else {
            throw Failure(message: L("@%@ has no .ipa files in the posts Telegram shows. Only the channel's recent posts are public.", channel))
        }
        // Newest first, by post date.
        entries.sort { ($0.latest?.date ?? .distantPast) > ($1.latest?.date ?? .distantPast) }
        return (title, entries)
    }

    // MARK: - The preview's markup

    private struct Post {
        let id: String
        let date: Date?
        let text: String?
        let documents: [(name: String, size: Int64?, sizeText: String?)]
        let links: [URL]
    }

    /// One post block per `tgme_widget_message_wrap`, the wrapper Telegram's own
    /// web client renders.
    private static func posts(in html: String) -> [Post] {
        var out: [Post] = []
        let chunks = html.components(separatedBy: #"<div class="tgme_widget_message_wrap"#)
        for chunk in chunks.dropFirst() {
            guard let id = firstMatch(#"data-post="[^/"]+/(\d+)""#, in: chunk) else { continue }
            let date = firstMatch(#"<time[^>]*datetime="([^"]+)""#, in: chunk).flatMap(iso.date(from:))

            // Document name and size, as the browser shows them.
            var documents: [(String, Int64?, String?)] = []
            for block in matches(#"<div class="tgme_widget_message_document_title[^>]*>([^<]*)</div>"#, in: chunk) {
                let title = decodeEntities(block)
                let sizeText = firstMatch(#"tgme_widget_message_document_extra[^>]*>([^<]*)<"#, in: chunk)
                documents.append((title, nil, sizeText.map(decodeEntities)))
            }

            let text = firstMatch(#"<div class="tgme_widget_message_text[^"]*"[^>]*>(.*?)</div>"#, in: chunk)
                .map(stripTags)
                .map(decodeEntities)

            let links = matches(#"href="(https?://[^"]+)""#, in: chunk)
                .compactMap { URL(string: decodeEntities($0)) }
                // Telegram's own links and stickers aren't downloads.
                .filter { $0.host?.contains("telegram") != true && $0.host != "t.me" }

            out.append(Post(id: id, date: date, text: text,
                            documents: documents.map { (name: $0.0, size: $0.1, sizeText: $0.2) },
                            links: links))
        }
        return out
    }

    /// "Naked.ipa" → "Naked"; the extension is noise in a list of apps.
    private static func displayName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".ipa") { name.removeLast(4) }
        return name.isEmpty ? raw : name
    }

    /// A version out of a file name or a caption, when one is written like one.
    private static func version(in text: String?) -> String? {
        guard let text else { return nil }
        return firstMatch(#"v?(\d+\.\d+(?:\.\d+)?)"#, in: text)
    }

    private static func byteCount(_ text: String?) -> Int64? {
        guard let text else { return nil }
        let upper = text.uppercased().replacingOccurrences(of: ",", with: ".")
        let value = Double(upper.replacingOccurrences(of: "GB", with: "")
            .replacingOccurrences(of: "MB", with: "")
            .replacingOccurrences(of: "KB", with: "")
            .trimmingCharacters(in: .whitespaces)) ?? 0
        if upper.contains("GB") { return Int64(value * 1_073_741_824) }
        if upper.contains("MB") { return Int64(value * 1_048_576) }
        if upper.contains("KB") { return Int64(value * 1_024) }
        return nil
    }

    // MARK: - Small HTML helpers

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
