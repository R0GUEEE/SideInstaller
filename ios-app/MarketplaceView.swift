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
    }

    /// What the right-hand side is showing.
    enum Filter: Hashable {
        case all
        case featured
        case category(String)
        case source(String)
    }

    @State private var filter: Filter? = .all
    @State private var query = ""
    @State private var catalog: [Listing] = []
    @State private var selected: Listing?
    @State private var showAdd = false
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle(L("Marketplace"))
                .navigationBarTitleDisplayMode(.inline)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(item: $selected) { listing in
            NavigationStack {
                AltAppView(app: listing.app, source: listing.source)
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
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $filter) {
            Section(L("Browse")) {
                row(.all, title: L("All apps"), icon: "square.grid.2x2.fill", count: catalog.count)
                if !featuredIDs.isEmpty {
                    row(.featured, title: L("Featured"), icon: "star.fill",
                        count: catalog.filter { featuredIDs.contains($0.app.bundleIdentifier ?? "") }.count)
                }
            }
            let categories = presentCategories
            if !categories.isEmpty {
                Section(L("Categories")) {
                    ForEach(categories) { category in
                        row(.category(category.id), title: category.title, icon: category.icon,
                            count: catalog.filter { MarketCategory.of($0.app.category) == category }.count)
                    }
                }
            }
            Section(L("Sources")) {
                ForEach(store.sources) { loaded in
                    row(.source(loaded.id), title: loaded.name, icon: "shippingbox.fill",
                        count: loaded.appCount)
                }
                Button {
                    showAdd = true
                } label: {
                    Label(L("Add a source"), systemImage: "plus.circle.fill")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .refreshable { await store.refreshAll() }
        .toolbar { settingsToolbarItem(isPresented: $showSettings) }
    }

    private func row(_ value: Filter, title: String, icon: String, count: Int) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        } icon: {
            Image(systemName: icon)
        }
        .tag(value)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        ScrollView {
            // Lazy: a source can list hundreds of apps, and only the visible
            // cards should exist.
            LazyVStack(alignment: .leading, spacing: 18) {
                header
                if visible.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 14)],
                              spacing: 14) {
                        ForEach(visible) { listing in
                            Button {
                                selected = listing
                            } label: {
                                ListingCard(listing: listing)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    install(listing)
                                } label: {
                                    Label(L("Install"), systemImage: "square.and.arrow.down")
                                }
                                Button {
                                    selected = listing
                                } label: {
                                    Label(L("Details"), systemImage: "info.circle")
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
            .pageColumn()
        }
        .background(AppBackground())
        .searchable(text: $query, prompt: Text(L("Search every source")))
        .refreshable { await store.refreshAll() }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.largeTitle.weight(.bold))
            Text(visible.count == 1 ? L("1 app") : L("%ld apps", visible.count))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
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

    /// Every app in every source, one entry per bundle ID (the newest release a
    /// source lists wins), so the same app in two sources isn't listed twice.
    private func rebuild() {
        var byBundle: [String: Listing] = [:]
        var order: [String] = []
        for loaded in store.sources {
            guard let source = loaded.source else { continue }
            for app in source.installableApps {
                let key = app.bundleIdentifier ?? app.id
                if let existing = byBundle[key] {
                    let old = existing.app.latest?.version ?? "0"
                    let new = app.latest?.version ?? "0"
                    if new.compare(old, options: .numeric) == .orderedAscending { continue }
                } else {
                    order.append(key)
                }
                byBundle[key] = Listing(app: app, source: source)
            }
        }
        let rebuilt = order.compactMap { byBundle[$0] }
        if rebuilt.map(\.id) != catalog.map(\.id) { catalog = rebuilt }
    }

    /// The categories the sources actually use, in the catalogue's order.
    private var presentCategories: [MarketCategory] {
        let used = Set(catalog.map { MarketCategory.of($0.app.category) })
        return MarketCategory.all.filter { used.contains($0) }
    }

    private var featuredIDs: Set<String> {
        var out: Set<String> = []
        for loaded in store.sources {
            for id in loaded.source?.featuredApps ?? [] { out.insert(id) }
        }
        return out
    }

    private var visible: [Listing] {
        var list = catalog
        switch filter ?? .all {
        case .all:
            break
        case .featured:
            list = list.filter { featuredIDs.contains($0.app.bundleIdentifier ?? "") }
        case .category(let id):
            list = list.filter { MarketCategory.of($0.app.category).id == id }
        case .source(let id):
            list = list.filter { $0.source.id == id }
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return list }
        return list.filter {
            $0.app.name.localizedCaseInsensitiveContains(trimmed)
                || ($0.app.developerName ?? "").localizedCaseInsensitiveContains(trimmed)
                || ($0.app.bundleIdentifier ?? "").localizedCaseInsensitiveContains(trimmed)
                || ($0.app.subtitle ?? "").localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Installs the newest release of a listing, without opening its page first.
    private func install(_ listing: Listing) {
        guard let url = listing.app.latest?.url else { return }
        engine.installLinkedIPA(url)
    }
}

/// One app in the grid: its icon, name and developer, with the newest version
/// underneath.
private struct ListingCard: View {
    let listing: MarketplaceView.Listing

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                SourceIcon(url: listing.app.icon, side: 54, fallback: "app.fill", corner: 13)
                    .shadow(color: Theme.glow, radius: 10, x: 0, y: 5)
                Spacer(minLength: 0)
                if let version = listing.app.latest?.version {
                    Text(version)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.07)))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(listing.app.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(listing.app.developerName ?? listing.source.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(MarketCategory.of(listing.app.category).title)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
