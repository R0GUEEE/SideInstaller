import Combine
import Foundation

/// A line of installs, run one after another.
///
/// The pipeline signs and installs one app at a time — they share a device link,
/// one pairing file and Apple's rate limit — so a queue is the honest shape for
/// "do these five". Each item also remembers the newest release it was given, so
/// a failed one can be retried without hunting for the link again.
@MainActor
final class InstallQueue: ObservableObject {

    static let shared = InstallQueue()

    struct Item: Identifiable, Equatable {
        enum State: Equatable {
            case waiting
            case installing
            case done
            case failed(String)
        }

        let id = UUID()
        var name: String
        var url: URL
        /// The bundle ID, when it's known before the download.
        var bundleID: String?
        var state: State = .waiting

        var isFinished: Bool {
            switch state {
            case .done, .failed: return true
            case .waiting, .installing: return false
            }
        }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isRunning = false

    private var runner: Task<Void, Never>?

    private init() {}

    var pending: [Item] { items.filter { !$0.isFinished } }

    /// Adds a build to the end of the line. Returns false when it's already in it.
    @discardableResult
    func add(name: String, url: URL, bundleID: String? = nil) -> Bool {
        guard !items.contains(where: { $0.url == url && !$0.isFinished }) else { return false }
        items.append(Item(name: name, url: url, bundleID: bundleID))
        return true
    }

    func remove(_ id: UUID) {
        guard !isRunning else { return }
        items.removeAll { $0.id == id }
    }

    func clearFinished() {
        items.removeAll { $0.isFinished }
    }

    func clearAll() {
        guard !isRunning else { return }
        items.removeAll()
    }

    /// Starts the line. Does nothing when it's already running or empty.
    func start() {
        guard !isRunning, !pending.isEmpty else { return }
        isRunning = true
        runner = Task { [weak self] in
            await self?.run()
        }
    }

    func cancel() {
        runner?.cancel()
        runner = nil
        isRunning = false
        for index in items.indices where items[index].state == .waiting {
            items[index].state = .failed(L("Cancelled"))
        }
        // Whatever is mid-install finishes or stops on its own: the engine owns
        // that run, and cancelling it from here would leave a half-signed app.
        if Engine.shared.isRunning { Engine.shared.cancelOneClick() }
    }

    private func run() async {
        defer { isRunning = false }
        while !Task.isCancelled, let next = items.first(where: { $0.state == .waiting }) {
            guard let index = items.firstIndex(where: { $0.id == next.id }) else { break }
            items[index].state = .installing
            Engine.shared.installLinkedIPA(next.url)
            // Wait for the run to end. The engine is the only thing that knows
            // when signing, pairing work and installation are all finished.
            var waited = 0.0
            while Engine.shared.isRunning || Engine.shared.isImportingIPA {
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                waited += 1
                // A run that hangs on a prompt shouldn't stall the line forever.
                if waited > 900 { break }
            }
            guard let at = items.firstIndex(where: { $0.id == next.id }) else { break }
            if let error = Engine.shared.lastError, !error.isEmpty, !Engine.shared.isRunning {
                items[at].state = .failed(error)
                Engine.shared.lastError = nil
            } else {
                items[at].state = .done
            }
            // A pause between installs: Apple's API dislikes bursts, and the
            // device link needs a moment to settle.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}

/// What has been installed, and how to get back to it.
///
/// Every successful install records the build and the copy `IPACache` kept, so
/// "roll back to what I had" is a row in a list rather than a search for an old
/// download.
@MainActor
final class InstallHistory: ObservableObject {

    static let shared = InstallHistory()

    struct Entry: Identifiable, Codable {
        let id: UUID
        let bundleID: String
        let name: String
        let version: String?
        /// Where the copy is, relative to the app container. Stored so a change
        /// in container paths between launches doesn't break old records.
        let cachedPath: String?
        let date: Date
        /// Where it came from, for the row: a source's name, "imported", a queue…
        let origin: String?

        var cachedURL: URL? {
            guard let cachedPath else { return nil }
            let url = URL(fileURLWithPath: cachedPath)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    @Published private(set) var entries: [Entry] = []

    private static let defaultsKey = "install.history.v1"
    private static let limit = 200

    private init() {
        entries = Self.load()
    }

    /// Records a successful install. Called by the engine once an install ends.
    func record(bundleID: String, name: String, version: String?,
                cached: URL?, origin: String?) {
        // Repeating the same build shouldn't stack up identical rows.
        if let last = entries.first, last.bundleID == bundleID,
           last.version == version,
           Date().timeIntervalSince(last.date) < 60 {
            return
        }
        let entry = Entry(id: UUID(), bundleID: bundleID, name: name, version: version,
                          cachedPath: cached?.path, date: Date(), origin: origin)
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    /// The newest earlier build of `bundleID` that's still on disk — what a roll
    /// back would install.
    func previousBuild(of bundleID: String) -> Entry? {
        entries.filter { $0.bundleID == bundleID && $0.cachedURL != nil }
            .dropFirst()
            .first
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private static func load() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries
    }
}
