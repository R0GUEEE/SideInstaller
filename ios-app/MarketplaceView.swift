import SwiftUI

/// A category an app can be filed under, in the vocabulary AltStore sources
/// use, with the name and symbol an App Store-style grid wants.
struct MarketCategory: Identifiable, Hashable {
    let id: String        // the source's `category` value
    let title: String
    let icon: String

    /// Every category a source may name. Unknown ones fall back to `other`.
    /// Computed rather than stored so the names follow a language change.
    static var all: [MarketCategory] { [
        .init(id: "utilities", title: L("Utilities"), icon: "wrench.and.screwdriver.fill"),
        .init(id: "games", title: L("Games"), icon: "gamecontroller.fill"),
        .init(id: "developer", title: L("Developer"), icon: "hammer.fill"),
        .init(id: "social", title: L("Social"), icon: "person.2.fill"),
        .init(id: "entertainment", title: L("Entertainment"), icon: "play.tv.fill"),
        .init(id: "education", title: L("Education"), icon: "graduationcap.fill"),
        .init(id: "graphics-design", title: L("Graphics & Design"), icon: "paintpalette.fill"),
        .init(id: "health-fitness", title: L("Health & Fitness"), icon: "heart.fill"),
        .init(id: "lifestyle", title: L("Lifestyle"), icon: "sparkles"),
        .init(id: "music", title: L("Music"), icon: "music.note"),
        .init(id: "news", title: L("News"), icon: "newspaper.fill"),
        .init(id: "photo-video", title: L("Photo & Video"), icon: "camera.fill"),
        .init(id: "productivity", title: L("Productivity"), icon: "checklist"),
        .init(id: "travel", title: L("Travel"), icon: "airplane"),
        .init(id: "weather", title: L("Weather"), icon: "cloud.sun.fill"),
        .init(id: "books", title: L("Books"), icon: "book.fill"),
        .init(id: "business", title: L("Business"), icon: "briefcase.fill"),
        .init(id: "finance", title: L("Finance"), icon: "dollarsign.circle.fill"),
        .init(id: "medical", title: L("Medical"), icon: "cross.case.fill"),
        .init(id: "navigation", title: L("Navigation"), icon: "map.fill"),
        .init(id: "reference", title: L("Reference"), icon: "text.book.closed.fill"),
        .init(id: "shopping", title: L("Shopping"), icon: "bag.fill"),
        .init(id: "sports", title: L("Sports"), icon: "figure.run"),
        .init(id: "food-drink", title: L("Food & Drink"), icon: "fork.knife"),
        .init(id: "other", title: L("Other"), icon: "square.grid.2x2.fill"),
    ] }

    private static var byID: [String: MarketCategory] {
        Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The category a source named, matched loosely (`Games`, `games`, a missing
    /// value all end up somewhere sensible).
    static func of(_ raw: String?) -> MarketCategory {
        let key = (raw ?? "").lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "&", with: "")
            .replacingOccurrences(of: "--", with: "-")
        return byID[key] ?? byID["other"]!
    }
}

/// The marketplace: every app in every configured source, browsable by category
/// the way an App Store is, with one-tap installation.
///
/// Pushed from Tools, so it takes the whole screen; the sidebar is its left
/// menu and the grid is the store itself.
struct MarketplaceView: View {
    @EnvironmentObject private var engine: Engine
    @EnvironmentObject private var loc: Localizer
    @ObservedObject var store: SourceStore

    /// One app, with the source that carries it.
    struct Listing: Identifiable {
        let app: AltApp
        let source: AltSource
        var id: String { source.id + "/" + app.id }

        /// When this app was last updated, for the date sorts. Sources that
        /// omit the date sort last rather than first.
        var date: Date? { app.latest?.dateValue }

        /// The newest release's download size, when the source lists one.
        var size: Int64? { app.latest?.size }
    }

    /// One app as the list shows it: every source's copy of it merged, with
    /// every release from all of them, so a version picker has the lot.
    struct MergedApp: Identifiable {
        let key: String
        let name: String
        let developer: String?
        let subtitle: String?
        let iconURL: String?
        let categoryID: String
        /// Newest first, one per version string, each with the source it's in.
        let versions: [(version: AltVersion, source: AltSource)]

        var id: String { key }
        var latest: AltVersion? { versions.first?.version }
        var date: Date? { latest?.dateValue }
        var size: Int64? { latest?.size }
        var icon: URL? { URL(string: iconURL ?? "") }
        var category: MarketCategory { MarketCategory.of(categoryID) }

        /// The release `version` picks out, or the newest.
        func pick(_ chosen: AltVersion?) -> (version: AltVersion, source: AltSource)? {
            guard let chosen else { return versions.first }
            return versions.first { $0.version.id == chosen.id } ?? versions.first
        }
    }

    /// What the right-hand side is showing.
    enum Filter: Hashable {
        case all
        case featured
        case category(String)
        case source(String)
    }

    /// The orders the list can be read in.
    enum SortOrder: String, CaseIterable, Identifiable {
        case name, newest, oldest, size

        var id: String { rawValue }

        var title: String {
            switch self {
            case .name:   return L("Name")
            case .newest: return L("Newest")
            case .oldest: return L("Oldest")
            case .size:   return L("Size")
            }
        }

        var icon: String {
            switch self {
            case .name:   return "textformat.abc"
            case .newest: return "calendar.badge.clock"
            case .oldest: return "calendar"
            case .size:   return "arrow.up.arrow.down.square"
            }
        }
    }

    @State private var filter: Filter? = .all
    @State private var query = ""
    /// Every app, one entry per bundle ID, with all of its versions merged.
    @State private var catalog: [MergedApp] = []
    /// The same apps kept per source, so a source's view shows everything it
    /// carries. Filtering the de-duplicated catalogue by source dropped any app
    /// a later source also listed — which is why a source with six apps showed
    /// none.
    @State private var bySource: [String: [MergedApp]] = [:]
    /// How the list is ordered. Applies to every view, including a source's own
    /// shelf, so the same list can be read newest-first or alphabetically.
    @State private var sort: SortOrder = .name
    @State private var selected: MergedApp?
    @State private var showAdd = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                rail
                Rectangle()
                    .fill(Color(.separator))
                    .frame(width: 1)
                content
            }
            .background(AppBackground())
            .toolbar { settingsToolbarItem(isPresented: $showSettings) }
            .sheet(item: $selected) { app in
                NavigationStack {
                    MergerAppView(app: app)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(L("Done")) { selected = nil }
                            }
                        }
                }
            }
            .sheet(isPresented: $showAdd) { AddSourceSheet(store: store) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .onAppear {
                store.load()
                rebuild()
            }
            .onChange(of: store.sources.map(\.id)) { _, _ in rebuild() }
            .onChange(of: store.sources.map(\.appCount)) { _, _ in rebuild() }
            // An install takes over the Install tab, so the app's page closes
            // itself rather than sitting over the run's progress.
            .onChange(of: engine.isRunning) { _, running in
                if running { selected = nil }
            }
        }
    }

    // MARK: The left menu

    /// A rail rather than a `List`: a split view's selection doesn't push
    /// anything at compact width, which is how this screen is almost always
    /// seen, and rows that don't open are worse than no rows. Buttons work at
    /// every width.
    private var rail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 4) {
                Text(L("Browse"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)

                railButton(.all, title: L("All apps"), icon: "square.grid.2x2.fill",
                           count: catalog.count)
                if !featuredIDs.isEmpty {
                    railButton(.featured, title: L("Featured"), icon: "star.fill",
                               count: catalog.filter { featuredIDs.contains($0.app.bundleIdentifier ?? "") }.count)
                }

                let categories = presentCategories
                if !categories.isEmpty {
                    Text(L("Categories"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.top, 12)
                    ForEach(categories) { category in
                        railButton(.category(category.id), title: category.title, icon: category.icon,
                                   count: catalog.filter { MarketCategory.of($0.app.category) == category }.count)
                    }
                }

                Text(L("Sources"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.top, 12)
                ForEach(store.sources) { loaded in
                    railButton(.source(loaded.id), title: loaded.name, icon: "shippingbox.fill",
                               count: bySource[loaded.id]?.count ?? loaded.appCount,
                               failed: loaded.error != nil)
                }
                Button {
                    showAdd = true
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                        Text(L("Add source"))
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundStyle(Theme.accent2)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.top, 6)
            }
            .padding(.vertical, 8)
        }
        .frame(width: 76)
        // The rail is its own column: on iPad's wider layout the same width
        // keeps the grid roomy.
        .background(.black.opacity(0.12))
    }

    private func railButton(_ value: Filter, title: String, icon: String, count: Int,
                            failed: Bool = false) -> some View {
        let selected = (filter ?? .all) == value
        return Button {
            filter = value
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                Text(title)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
                if failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.orange))
                } else if count > 0 {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(selected ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.clear))
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }

    // MARK: The grid

    private var content: some View {
        ScrollView {
            // Lazy: a source can list hundreds of apps, and only the visible
            // cards should exist.
            LazyVStack(alignment: .leading, spacing: 18) {
                header
                if visible.isEmpty {
                    emptyState
                } else {
                    // Compact rows rather than a grid of cards: more apps per
                    // screen, and the install button sits on the row.
                    LazyVStack(spacing: 8) {
                        ForEach(visible) { app in
                            HStack(spacing: 10) {
                                Button {
                                    selected = app
                                } label: {
                                    ListingRow(app: app)
                                }
                                .buttonStyle(.plain)

                                // One tap installs the newest; the menu offers
                                // every version the sources carry.
                                Button {
                                    install(app)
                                } label: {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(Theme.accent2)
                                }
                                .buttonStyle(.plain)
                                .disabled(app.latest?.url == nil || engine.isRunning)

                                if app.versions.count > 1 {
                                    Menu {
                                        ForEach(app.versions, id: \.version.id) { entry in
                                            Button {
                                                install(app, version: entry.version)
                                            } label: {
                                                Text(versionLabel(entry.version))
                                            }
                                        }
                                    } label: {
                                        Image(systemName: "chevron.down.circle")
                                            .font(.title3)
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.trailing, 2)
                            .contextMenu {
                                Button {
                                    install(app)
                                } label: {
                                    Label(L("Install newest"), systemImage: "square.and.arrow.down")
                                }
                                ForEach(app.versions, id: \.version.id) { entry in
                                    Button {
                                        install(app, version: entry.version)
                                    } label: {
                                        Label(L("Install %@", versionLabel(entry.version)),
                                              systemImage: "clock.arrow.circlepath")
                                    }
                                }
                                Divider()
                                Button {
                                    selected = app
                                } label: {
                                    Label(L("Details"), systemImage: "info.circle")
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .searchable(text: $query, prompt: Text(L("Search every source")))
        .refreshable { await store.refreshAll() }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.title2.weight(.bold))
            Text(visible.count == 1 ? L("1 app") : L("%ld apps", visible.count))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Menu {
                Picker(L("Sort by"), selection: $sort) {
                    ForEach(SortOrder.allCases) { order in
                        Label(order.title, systemImage: order.icon).tag(order)
                    }
                }
            } label: {
                Label(sort.title, systemImage: "arrow.up.arrow.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent2)
            }
        }
        .padding(.bottom, 2)
    }

    private var emptyState: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                if store.sources.isEmpty {
                    Text(L("No sources yet"))
                        .font(.headline)
                    Text(L("Add an AltStore source to browse and install its apps from here."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button(L("Add a source")) { showAdd = true }
                        .buttonStyle(PrimaryButtonStyle())
                } else if store.sources.allSatisfy({ $0.source == nil }) {
                    Text(L("Loading…"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ProgressView()
                } else if case .source(let id) = filter ?? .all,
                          let loaded = store.sources.first(where: { $0.id == id }),
                          let error = loaded.error {
                    Text(L("%@ didn't load", loaded.name))
                        .font(.headline)
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task { await store.refresh(id) }
                    } label: {
                        Label(L("Try again"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                } else if !query.isEmpty {
                    Text(L("No app matches “%@”.", query))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L("Nothing here yet"))
                        .font(.headline)
                    Text(L("This part of the marketplace has no apps in it."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Data

    private var title: String {
        switch filter ?? .all {
        case .all:                        return L("All apps")
        case .featured:                   return L("Featured")
        case .category(let id):           return MarketCategory.all.first { $0.id == id }?.title ?? L("Apps")
        case .source(let id):             return store.sources.first { $0.id == id }?.name ?? L("Source")
        }
    }

    /// Every app in every source, one entry per bundle ID. Two sources listing
    /// the same app are one entry, and the union of their releases is what the
    /// version picker offers.
    private func rebuild() {
        struct Group {
            var listing: Listing
            var versions: [AltVersion]
            var sources: [AltSource]
        }
        var groups: [String: Group] = [:]
        var order: [String] = []
        var perSource: [String: [String]] = [:]

        for loaded in store.sources {
            guard let source = loaded.source else { continue }
            for app in source.installableApps {
                let key = app.bundleIdentifier ?? app.id
                if groups[key] == nil {
                    groups[key] = Group(listing: Listing(app: app, source: source),
                                        versions: [], sources: [source])
                    order.append(key)
                }
                guard var group = groups[key] else { continue }
                if !group.sources.contains(where: { $0.id == source.id }) {
                    group.sources.append(source)
                }
                group.versions.append(contentsOf: app.releases)
                // The entry shown is whichever source has the newest release.
                let current = group.listing.app.latest?.dateValue ?? .distantPast
                if (app.latest?.dateValue ?? .distantPast) > current {
                    group.listing = Listing(app: app, source: source)
                }
                groups[key] = group
                perSource[loaded.id, default: []].append(key)
            }
        }

        var merged: [String: MergedApp] = [:]
        for (key, group) in groups {
            // One release per version, newest first; a build two sources both
            // carry is listed once, under the first source that has it.
            var seen = Set<String>()
            var versions: [(version: AltVersion, source: AltSource)] = []
            let sorted = group.versions.sorted { lhs, rhs in
                let left = lhs.dateValue ?? .distantPast
                let right = rhs.dateValue ?? .distantPast
                if left != right { return left > right }
                return (lhs.version ?? "").compare(rhs.version ?? "", options: .numeric) == .orderedDescending
            }
            for release in sorted {
                let tag = release.version ?? release.id
                guard seen.insert(tag).inserted else { continue }
                let owner = group.sources.first { source in
                    source.installableApps.contains { $0.releases.contains { $0.id == release.id } }
                } ?? group.listing.source
                versions.append((release, owner))
            }
            let app = group.listing.app
            merged[key] = MergedApp(key: key,
                                    name: app.name,
                                    developer: app.developerName,
                                    subtitle: app.subtitle,
                                    iconURL: app.iconURL,
                                    categoryID: app.category ?? "",
                                    versions: versions)
        }

        let rebuilt = order.compactMap { merged[$0] }
        if rebuilt.map(\.id) != catalog.map(\.id) { catalog = rebuilt }

        var grouped: [String: [MergedApp]] = [:]
        for (sourceID, keys) in perSource {
            grouped[sourceID] = keys.compactMap { merged[$0] }
        }
        if grouped.mapValues(\.count) != bySource.mapValues(\.count) { bySource = grouped }
    }

    /// The categories the sources actually use, in the catalogue's order.
    private var presentCategories: [MarketCategory] {
        let used = Set(catalog.map(\.category))
        return MarketCategory.all.filter { used.contains($0) }
    }

    private var featuredIDs: Set<String> {
        var out: Set<String> = []
        for loaded in store.sources {
            for id in loaded.source?.featuredApps ?? [] { out.insert(id) }
        }
        return out
    }

    /// What the current view shows: filtered by the search field, ordered by
    /// `sort`.
    private var visible: [MergedApp] {
        var list = catalog
        switch filter ?? .all {
        case .all:
            break
        case .featured:
            list = list.filter { featuredIDs.contains($0.key) }
        case .category(let id):
            list = list.filter { $0.category.id == id }
        case .source(let id):
            // Not the de-duplicated list: this view is this source's shelf.
            list = bySource[id] ?? []
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(trimmed)
                    || ($0.developer ?? "").localizedCaseInsensitiveContains(trimmed)
                    || ($0.subtitle ?? "").localizedCaseInsensitiveContains(trimmed)
                    || $0.key.localizedCaseInsensitiveContains(trimmed)
            }
        }
        return sorted(list)
    }

    /// "1.2.3 · 3 Feb 2026", as the version menus show a release.
    private func versionLabel(_ version: AltVersion) -> String {
        var parts = [version.version ?? L("unknown")]
        if let date = version.dateValue {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: " · ")
    }

    private func sorted(_ list: [MergedApp]) -> [MergedApp] {
        switch sort {
        case .name:
            return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .newest:
            return list.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        case .oldest:
            return list.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        case .size:
            // Largest first: the size worth knowing about is the big one.
            return list.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        }
    }

    /// Installs the chosen release of an app (or the newest) without opening its
    /// page first.
    private func install(_ app: MergedApp, version: AltVersion? = nil) {
        guard let picked = app.pick(version), let url = picked.version.url else { return }
        engine.installLinkedIPA(url)
    }
}

/// One app's page, assembled from every source that carries it.
///
/// The marketplace merges an app's copies so it's listed once; this is what
/// opens when one is tapped, with the union of its releases and a picker to
/// choose which one to install.
struct MergerAppView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var engine: Engine
    let app: MarketplaceView.MergedApp

    @State private var chosen: AltVersion?
    @State private var showVersions = false

    private var picked: (version: AltVersion, source: AltSource)? { app.pick(chosen) }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                hero
                if let description = app.subtitle ?? picked?.version.localizedDescription,
                   !description.isEmpty {
                    PanelCard {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                releaseCard
                sourcesCard
                installCard
            }
            .padding(20)
            .pageColumn()
        }
        .background(AppBackground())
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hero: some View {
        VStack(spacing: 12) {
            SourceIcon(url: app.icon, side: 92, fallback: "app.fill", corner: 22)
                .shadow(color: Theme.glow, radius: 18, x: 0, y: 10)
            VStack(spacing: 4) {
                Text(app.name)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                if let developer = app.developer, !developer.isEmpty {
                    Text(developer)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(app.key)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            StatusPill(text: app.category.title, systemImage: app.category.icon, color: Theme.accent2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var releaseCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("Release"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showVersions = true
                    } label: {
                        Label(picked?.version.version ?? L("Newest"),
                              systemImage: "chevron.up.chevron.down")
                            .font(.subheadline.weight(.semibold))
                    }
                    .confirmationDialog(L("Choose a version"), isPresented: $showVersions) {
                        ForEach(app.versions, id: \.version.id) { entry in
                            Button(label(entry.version)) { chosen = entry.version }
                        }
                        Button(L("Cancel"), role: .cancel) {}
                    }
                }
                if let picked {
                    VStack(alignment: .leading, spacing: 8) {
                        if let date = picked.version.dateValue {
                            row(L("Released"), date.formatted(date: .abbreviated, time: .omitted))
                        }
                        if let size = picked.version.sizeText {
                            row(L("Size"), size)
                        }
                        if let minOS = picked.version.minOSVersion {
                            row(L("Needs iOS"), minOS, warn: picked.version.needsNewerOS)
                        }
                        row(L("From"), picked.source.name)
                    }
                } else {
                    Text(L("No downloadable release."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Every source carrying this app, and how many of its versions each has.
    private var sourcesCard: some View {
        let sources = Dictionary(grouping: app.versions, by: { $0.source.id })
        return PanelCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("In your sources"))
                    .font(.subheadline.weight(.semibold))
                ForEach(Array(sources.keys), id: \.self) { id in
                    if let entries = sources[id], let source = entries.first?.source {
                        HStack {
                            Text(source.name)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text(L("%ld versions", entries.count))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var installCard: some View {
        PanelCard {
            VStack(spacing: 12) {
                Button {
                    if let url = picked?.version.url { engine.installLinkedIPA(url) }
                } label: {
                    Label(L("Install %@", picked?.version.version ?? L("newest")),
                          systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(picked?.version.url == nil || engine.isRunning || engine.isImportingIPA)

                Text(L("Downloads the .ipa, signs it with your Apple ID and installs it — the same run as any other build."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func label(_ version: AltVersion) -> String {
        var parts = [version.version ?? L("unknown")]
        if let date = version.dateValue {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: " · ")
    }

    private func row(_ label: String, _ value: String, warn: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(AnyShapeStyle(warn ? Color.orange : Color.primary))
            Spacer(minLength: 0)
        }
    }
}

/// One app in the list: icon, name, developer and category, with the newest
/// version on the right. Deliberately small — the marketplace is for finding
/// and installing, and the app's own page has the rest.
private struct ListingRow: View {
    let app: MarketplaceView.MergedApp

    var body: some View {
        HStack(spacing: 12) {
            SourceIcon(url: app.icon, side: 44, fallback: "app.fill", corner: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(app.latest?.version ?? "")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                if app.versions.count > 1 {
                    Text(L("%ld versions", app.versions.count))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if let size = app.latest?.sizeText {
                    Text(size)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }

    /// "Developer · Category", with whatever of the two the source gave.
    private var subtitle: String {
        let category = app.category.title
        switch (app.developer?.isEmpty == false, category.isEmpty) {
        case (true, false):  return "\(app.developer!) · \(category)"
        case (true, true):   return app.developer!
        case (false, false): return category
        default:             return app.versions.first?.source.name ?? ""
        }
    }
}
