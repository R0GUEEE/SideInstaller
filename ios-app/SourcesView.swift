import SwiftUI
import UIKit

// MARK: - One source's apps

/// Every app a source lists, searchable, each opening its own page.
struct SourceDetailView: View {
    @EnvironmentObject private var loc: Localizer
    @ObservedObject var store: SourceStore
    let id: String

    @State private var query = ""
    /// The list the page draws: the source's apps filtered by `query`, worked
    /// out when either changes rather than on every body pass.
    @State private var filtered: [AltApp] = []

    private var loaded: SourceStore.Loaded? { store.sources.first { $0.id == id } }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                if let loaded {
                    banner(loaded).cascadeItem(0)
                    if let source = loaded.source {
                        if let description = source.description, !description.isEmpty {
                            PanelCard {
                                Text(markdown(description))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .cascadeItem(1)
                        }
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, app in
                            NavigationLink {
                                AltAppView(app: app, source: source)
                            } label: {
                                AppRow(app: app)
                            }
                            .buttonStyle(.plain)
                            // Capped: the cascade's delay is per index, so an
                            // uncapped one on a 600-app source hides the rows
                            // at the bottom for half a minute.
                            .cascadeItem(min(index + 2, 7))
                        }
                        if filtered.isEmpty {
                            PanelCard {
                                Text(query.isEmpty
                                     ? L("This source lists no apps that can be installed.")
                                     : L("No app here matches “%@”.", query))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .cascadeItem(2)
                        }
                    } else if let error = loaded.error {
                        PanelCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(error)
                                    .font(.subheadline)
                                    .foregroundStyle(.orange)
                                Button {
                                    Task { await store.refresh(id) }
                                } label: {
                                    Label(L("Try again"), systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .cascadeItem(1)
                    }
                }
            }
            .padding(20)
            .pageColumn()
        }
        .background(AppBackground())
        .searchable(text: $query, prompt: Text(L("Search apps")))
        .navigationTitle(loaded?.name ?? L("Source"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh(id) }
        .onAppear {
            store.load()
            refreshFilter()
        }
        .onChange(of: query) { _, _ in refreshFilter() }
        .onChange(of: loaded?.source?.installableApps.count) { _, _ in refreshFilter() }
    }

    /// Applies the search field to the source's list. Cheap: the list is
    /// already sorted, and the comparison is a substring test.
    private func refreshFilter() {
        guard let source = loaded?.source else {
            if !filtered.isEmpty { filtered = [] }
            return
        }
        let all = source.installableApps
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches: [AltApp]
        if trimmed.isEmpty {
            matches = all
        } else {
            matches = all.filter {
                $0.name.localizedCaseInsensitiveContains(trimmed)
                    || ($0.developerName ?? "").localizedCaseInsensitiveContains(trimmed)
                    || ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains(trimmed)
            }
        }
        if matches.map(\.id) != filtered.map(\.id) { filtered = matches }
    }

    private func banner(_ loaded: SourceStore.Loaded) -> some View {
        VStack(spacing: 12) {
            BrandHeader(icon: "shippingbox.fill", title: loaded.name) {
                if let subtitle = loaded.source?.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            if let url = loaded.url.host {
                Text(url)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Source descriptions are Markdown (AltStore renders them as such), so
    /// inline formatting is applied and the rest shown as written.
    private func markdown(_ text: String) -> AttributedString {
        let cleaned = text.replacingOccurrences(of: "\r\n", with: "\n")
        return (try? AttributedString(markdown: cleaned,
                                      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(cleaned)
    }
}

/// One app in a source's list.
private struct AppRow: View {
    let app: AltApp

    var body: some View {
        PanelCard {
            HStack(spacing: 14) {
                SourceIcon(url: app.icon, side: 46, fallback: "app.fill", corner: 11)

                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name)
                        .font(.headline)
                        .lineLimit(1)
                    if let developer = app.developerName, !developer.isEmpty {
                        Text(developer)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let subtitle = app.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let latest = app.latest?.version {
                    Text(latest)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - One app

/// An app's page: what it is, its screenshots, its releases, and the button
/// that installs the chosen one.
struct AltAppView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var engine: Engine
    let app: AltApp
    let source: AltSource

    @State private var releaseID: String?
    @State private var showVersionPicker = false

    private var releases: [AltVersion] { app.releases }
    private var release: AltVersion? {
        releases.first { $0.id == releaseID } ?? releases.first
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                hero.cascadeItem(0)
                if let description = app.localizedDescription, !description.isEmpty {
                    PanelCard {
                        Text(markdown(description))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .cascadeItem(1)
                }
                if !app.screenshotURLs.isEmpty { screenshots.cascadeItem(2) }
                releaseCard.cascadeItem(3)
                installCard.cascadeItem(4)
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
                if let developer = app.developerName, !developer.isEmpty {
                    Text(developer)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let bundleID = app.bundleIdentifier {
                    Text(bundleID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            Text(source.name)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var screenshots: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Screenshots"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(app.screenshotURLs, id: \.absoluteString) { url in
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Rectangle().fill(.white.opacity(0.06))
                        }
                        .frame(width: 150, height: 325)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
        }
    }

    private var releaseCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("Release"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if releases.count > 1 {
                        Button {
                            showVersionPicker = true
                        } label: {
                            Label(release?.version ?? L("Latest"), systemImage: "chevron.up.chevron.down")
                                .font(.subheadline.weight(.semibold))
                        }
                        .confirmationDialog(L("Choose a release"), isPresented: $showVersionPicker) {
                            ForEach(releases) { candidate in
                                Button(versionLabel(candidate)) { releaseID = candidate.id }
                            }
                            Button(L("Cancel"), role: .cancel) {}
                        }
                    } else if let version = release?.version {
                        Text(version)
                            .font(.subheadline.monospaced())
                    }
                }
                if let release {
                    VStack(alignment: .leading, spacing: 8) {
                        if let date = release.dateValue {
                            row(L("Released"), date.formatted(date: .abbreviated, time: .omitted))
                        }
                        if let size = release.sizeText {
                            row(L("Size"), size)
                        }
                        if let minOS = release.minOSVersion {
                            row(L("Needs iOS"), minOS, warn: release.needsNewerOS)
                        }
                        if let build = release.buildVersion {
                            row(L("Build"), build)
                        }
                    }
                } else {
                    Text(L("This app's source lists no release that can be downloaded."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func versionLabel(_ version: AltVersion) -> String {
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

    private var installCard: some View {
        PanelCard {
            VStack(spacing: 12) {
                Button {
                    guard let url = release?.url else { return }
                    engine.installLinkedIPA(url)
                } label: {
                    Label(L("Install with SideInstaller"), systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canInstall)

                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var canInstall: Bool {
        guard release?.url != nil else { return false }
        guard !(release?.needsNewerOS ?? false) else { return false }
        return !engine.isRunning && !engine.isImportingIPA
    }

    private var explanation: String {
        if let release, release.needsNewerOS {
            return L("This release needs iOS %@, and this iPhone runs iOS %@.",
                     release.minOSVersion ?? "?", ProcessInfo.processInfo.operatingSystemVersionString)
        }
        if engine.isRunning {
            return L("An install is already running. Open the Install tab to follow it.")
        }
        return L("SideInstaller downloads the .ipa, reads it, then signs it with your Apple ID and installs it — the same run as any other build. Follow it on the Install tab.")
    }

    private func markdown(_ text: String) -> AttributedString {
        let cleaned = text.replacingOccurrences(of: "\r\n", with: "\n")
        return (try? AttributedString(markdown: cleaned,
                                      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(cleaned)
    }
}

// MARK: - Adding a source

/// The sheet that takes a source link. Open-ended on purpose: any URL that
/// answers with the format works.
struct AddSourceSheet: View {
    @EnvironmentObject private var loc: Localizer
    @ObservedObject var store: SourceStore
    /// A link that brought the user here, ready to add.
    var prefilled: String = ""
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L("Paste the address of a source"))
                        .font(.headline)
                    Text(L("It's the link to the source's JSON file — usually ending in .json, or a source's website address (AltStore's own is apps.altstore.io). An altstore://source link works too."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    TextField(L("https://apps.altstore.io"), text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($focused)
                        .fieldBackground()

                    if let error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }

                    if store.isAdding {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(L("Reading the source…"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        add()
                    } label: {
                        Label(L("Add source"), systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isAdding)

                    if store.sources.count > 0 {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("In this list"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(store.sources) { loaded in
                                HStack(spacing: 8) {
                                    Text(loaded.name)
                                        .font(.footnote)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    Button(role: .destructive) {
                                        store.remove(loaded.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.footnote)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(20)
            }
            .background(AppBackground())
            .navigationTitle(L("Add a source"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
            }
            .onAppear {
                if text.isEmpty { text = prefilled }
                focused = true
            }
        }
    }

    private func add() {
        error = nil
        Task {
            if let message = await store.add(text) {
                error = message
            } else {
                dismiss()
            }
        }
    }
}

// MARK: - Icons

/// A source's or an app's icon, loaded once per URL and kept in memory.
///
/// `AsyncImage` was doing this per row, and on a source with hundreds of apps
/// every list pass re-requested and re-decoded them. A plain cache keyed by URL
/// — plus a hard limit on the image size — keeps scrolling smooth.
struct SourceIcon: View {
    let url: URL?
    var side: CGFloat = 46
    var fallback = "app.fill"
    var corner: CGFloat = 12

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Theme.brand)
                Image(systemName: fallback)
                    .font(.system(size: side * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        // No transition: a list that scrolls shouldn't cross-fade every icon.
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            if image != nil { image = nil }
            return
        }
        if let cached = SourceIconCache.shared.image(for: url) {
            if image !== cached { image = cached }
            return
        }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true,
              data.count < 4 << 20,
              let decoded = UIImage(data: data)
        else { return }
        SourceIconCache.shared.store(decoded, for: url)
        image = decoded
    }
}

/// The in-memory icon cache behind `SourceIcon`. Count-limited, since a big
/// source can carry hundreds of icons and each one is a full-size PNG.
final class SourceIconCache {
    static let shared = SourceIconCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 256
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    func store(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url.absoluteString as NSString)
    }
}
