import SwiftUI

/// AltStore-format sources: a list the user keeps, each one browsable, and any
/// app in them installable straight from here — SideInstaller signs it with the
/// Apple ID's certificate exactly as it signs its own builds, so no SideStore
/// needs to be running for the first install.
///
/// Pushed from Tools (relies on its `NavigationStack`).
struct SourcesView: View {
    /// Observed so labels redraw when the language changes.
    @EnvironmentObject private var loc: Localizer
    @ObservedObject var store: SourceStore

    @State private var showAdd = false
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header.cascadeItem(0)
                if store.sources.isEmpty {
                    emptyCard.cascadeItem(1)
                } else {
                    ForEach(Array(store.sources.enumerated()), id: \.element.id) { index, loaded in
                        NavigationLink {
                            SourceDetailView(store: store, id: loaded.id)
                        } label: {
                            SourceRow(loaded: loaded)
                        }
                        .buttonStyle(.plain)
                        .cascadeItem(index + 1)
                        .contextMenu {
                            Button(L("Remove"), role: .destructive) { store.remove(loaded.id) }
                        }
                    }
                }
                addCard.cascadeItem(store.sources.count + 1)
            }
            .padding(20)
            .pageColumn()
            .animation(.smooth(duration: 0.35), value: store.sources.map(\.id))
            .animation(.smooth(duration: 0.3), value: store.sources.map(\.appCount))
        }
        .background(AppBackground())
        .refreshable { await store.refreshAll() }
        .toolbar { settingsToolbarItem(isPresented: $showSettings) }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showAdd) {
            AddSourceSheet(store: store)
        }
        .onAppear { store.load() }
    }

    private var header: some View {
        BrandHeader(icon: "shippingbox.fill", title: L("Sources")) {
            if !store.sources.isEmpty {
                StatusPill(text: L("%ld apps", store.sources.reduce(0) { $0 + $1.appCount }),
                           systemImage: "square.grid.2x2.fill", color: Theme.accent2)
            }
        }
    }

    private var emptyCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("Browse a source"))
                    .font(.headline)
                Text(L("Sources are JSON catalogues of apps, the kind AltStore and SideStore read. Add one and every app it lists can be signed and installed here, without a computer and without SideStore."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var addCard: some View {
        Button {
            showAdd = true
        } label: {
            Label(L("Add a source"), systemImage: "plus.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryButtonStyle())
    }
}

/// One row in the sources list.
private struct SourceRow: View {
    let loaded: SourceStore.Loaded

    var body: some View {
        PanelCard {
            HStack(spacing: 14) {
                icon
                VStack(alignment: .leading, spacing: 3) {
                    Text(loaded.name)
                        .font(.headline)
                        .lineLimit(1)
                    subtitle
                }
                Spacer(minLength: 8)
                if loaded.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var icon: some View {
        AsyncImage(url: loaded.source?.icon) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Rectangle().fill(Theme.brand)
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 46, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var subtitle: some View {
        if let error = loaded.error {
            Text(error)
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
        } else if loaded.source != nil {
            Text(loaded.appCount == 1 ? L("1 app")
                                      : L("%ld apps", loaded.appCount))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text(L("Loading…"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - One source's apps

/// Every app a source lists, searchable, each opening its own page.
struct SourceDetailView: View {
    @EnvironmentObject private var loc: Localizer
    @ObservedObject var store: SourceStore
    let id: String

    @State private var query = ""

    private var loaded: SourceStore.Loaded? { store.sources.first { $0.id == id } }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
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
                        ForEach(Array(apps(in: source).enumerated()), id: \.element.id) { index, app in
                            NavigationLink {
                                AltAppView(app: app, source: source)
                            } label: {
                                AppRow(app: app)
                            }
                            .buttonStyle(.plain)
                            .cascadeItem(index + 2)
                        }
                        if apps(in: source).isEmpty {
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
        .onAppear { store.load() }
    }

    private func apps(in source: AltSource) -> [AltApp] {
        let all = source.installableApps
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || ($0.developerName ?? "").localizedCaseInsensitiveContains(trimmed)
                || ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains(trimmed)
        }
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
                AsyncImage(url: app.icon) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ZStack {
                        Rectangle().fill(.white.opacity(0.08))
                        Image(systemName: "app.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

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
            AsyncImage(url: app.icon) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Rectangle().fill(Theme.brand)
                    Image(systemName: "app.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 92, height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
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
