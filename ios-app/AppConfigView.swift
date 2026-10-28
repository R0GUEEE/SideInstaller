import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension UTType {
    /// A compiled tweak. Not declared in Info.plist: the picker only needs the
    /// extension to let a `.dylib` be chosen.
    static let dylib = UTType(filenameExtension: "dylib") ?? .data
    /// A jailbreak package. `debian-binary` isn't claimed by anything, so the
    /// extension is what identifies it.
    static let deb = UTType(filenameExtension: "deb") ?? .data
}

/// The full configuration toolkit for the custom `.ipa`: what the build says
/// about itself, any `Info.plist` key or entitlement, which extensions survive,
/// and the tweaks and injectors loaded into it.
///
/// Everything is read out of the imported archive when the page opens, so the
/// fields start from the build rather than from nothing.
struct AppConfigView: View {
    @EnvironmentObject private var loc: Localizer
    /// Which build the Install screen is pointed at — the page describes that
    /// one, never SideInstaller itself.
    @EnvironmentObject private var engine: Engine
    @ObservedObject private var store = AppConfigStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showTweakPicker = false
    @State private var showConfigImporter = false
    @State private var note: String?
    @State private var injectedFor: TweakInjectorKind?

    /// What the imported archive says, read once when the page opens.
    @State private var snapshot = Snapshot()
    @State private var isLoading = false
    /// True while the build's own values are being written into the fields, so
    /// that isn't mistaken for the user typing.
    @State private var applyingSnapshot = false

    /// The plain `.ipa` as it was imported, for the "in the build" lists.
    struct Snapshot {
        var bundleID = ""
        var name = ""
        var version = ""
        var build = ""
        var plist: [(key: String, kind: PlistEdit.Kind, text: String)] = []
        var entitlements: [(key: String, text: String)] = []
        var extensions: [String] = []
        /// The file the values came from, shown so it's clear which build they
        /// describe.
        var fileName = ""
        var missing = true
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 18) {
                    introCard
                    identityCard
                    plistCard
                    entitlementsCard
                    extensionsCard
                    tweaksCard
                    backupCard
                }
                .padding(20)
                .pageColumn()
            }
            .background(AppBackground())
            .navigationTitle(L("App configuration"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                }
            }
            .sheet(isPresented: $showTweakPicker) {
                FileImporterRepresentableView(allowedContentTypes: [.dylib, .deb],
                                             allowsMultipleSelection: true) { urls in
                    guard !urls.isEmpty else { return }
                    let result = store.addTweaks(urls)
                    note = result.failed.isEmpty
                        ? L("Added %d tweak(s).", result.added)
                        : L("Couldn't add %@.", result.failed.joined(separator: ", "))
                }
                .ignoresSafeArea()
            }
            .sheet(item: $injectedFor) { kind in
                FileImporterRepresentableView(allowedContentTypes: [.dylib]) { urls in
                    guard let url = urls.first else { return }
                    if !store.addInjector(kind, from: url) {
                        note = L("That file couldn't be added as %@.", kind.title)
                    }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showConfigImporter) {
                FileImporterRepresentableView(allowedContentTypes: [.json]) { urls in
                    guard let url = urls.first, let data = try? Data(contentsOf: url) else { return }
                    note = store.importData(data)
                        ? L("Configuration imported.")
                        : L("That isn't a configuration file this version understands.")
                }
                .ignoresSafeArea()
            }
            .task { await loadSnapshot() }
            // Switching the Install tab to another build re-reads that build.
            .onChange(of: engine.installSource) { _, _ in Task { await loadSnapshot(force: true) } }
            .onChange(of: engine.installMenuRevision) { _, _ in Task { await loadSnapshot(force: true) } }
        }
    }

    // MARK: Reading the build

    /// Reads the imported archive off the main actor: identity, every
    /// top-level plist key, the entitlements and the extension bundles.
    private func loadSnapshot(force: Bool = false) async {
        guard !isLoading else { return }
        if !force, !snapshot.fileName.isEmpty, snapshot.fileName == engine.installTargetIPA?.lastPathComponent {
            return
        }
        // The build the Install screen is set to install: a downloaded one, the
        // custom import, or the selected source's copy on disk. The running
        // app's own Info.plist is never used.
        guard let url = engine.installTargetIPA else {
            snapshot = Snapshot()
            return
        }
        isLoading = true
        let read = await Task.detached(priority: .userInitiated) { () -> Snapshot in
            guard let info = IPAPatch.readInfoPlist(from: url) else { return Snapshot() }
            var result = Snapshot()
            result.missing = false
            result.fileName = url.lastPathComponent
            result.bundleID = info["CFBundleIdentifier"] as? String ?? ""
            result.name = (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String) ?? ""
            result.version = info["CFBundleShortVersionString"] as? String ?? ""
            result.build = info["CFBundleVersion"] as? String ?? ""
            // The build's own keys, the useful ones first: identity and
            // interface before the long tail of privacy strings.
            result.plist = info.keys.sorted().compactMap { key in
                guard let value = info[key] else { return nil }
                return (key, PlistEdit.Kind.of(value), PlistEdit.Kind.text(value))
            }
            let entitlements = IPAPatch.readEntitlements(from: url) ?? [:]
            result.entitlements = entitlements.keys.sorted().compactMap { key in
                guard let value = entitlements[key] else { return nil }
                return (key, PlistEdit.Kind.text(value))
            }
            result.extensions = IPAInspector.extensionNames(in: url)
            return result
        }.value
        isLoading = false
        snapshot = read
        guard !read.missing else { return }
        applyIdentity(from: read)
    }

    /// Copies the build's identity into every field the user hasn't claimed.
    ///
    /// A pinned field is the user's own value — a rename, a second copy under
    /// another bundle ID — and is left alone. Everything else follows the build,
    /// so importing a different .ipa always shows that app's name and version
    /// rather than whatever the last one left behind.
    private func applyIdentity(from build: Snapshot) {
        applyingSnapshot = true
        defer { applyingSnapshot = false }
        for field in AppConfig.IdentityField.allCases where !store.isPinned(field) {
            let value: String
            switch field {
            case .bundleIdentifier: value = build.bundleID
            case .displayName:      value = build.name
            case .version:          value = build.version
            case .build:            value = build.build
            }
            if store.config[field] != value { store.config[field] = value }
        }
    }

    // MARK: Intro

    private var introCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(snapshot.missing ? L("No .ipa to configure yet")
                                     : L("Read from %@", snapshot.fileName))
                    .font(.headline)
                if snapshot.missing {
                    Text(L("Pick a build on the Install tab — or import one — and its values appear here, ready to change. If the Install tab is set to SideStore or LiveContainer, this describes that release's .ipa."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L("Everything below is applied when this build is signed. The imported file is replaced, so a refresh later reinstalls the same configured build."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if isLoading {
                        ProgressView().controlSize(.small)
                    }
                }
                if !store.config.summary.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.config.summary, id: \.self) { line in
                            Label(line, systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.accent2)
                        }
                    }
                    .padding(.top, 2)
                }
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Identity

    private var identityCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    header(L("Identity"), systemImage: "app.badge")
                    Spacer()
                    Button {
                        Task { await loadSnapshot(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                }

                Text(snapshot.missing
                     ? L("Import a build and its identity appears here.")
                     : L("These come from %@. Change one and it becomes yours; the rest keep following the build.", snapshot.fileName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                identityField(.bundleIdentifier, hint: "com.example.app", monospaced: true)
                Text(L("A new bundle ID installs alongside the original and registers its own App ID, which a free Apple ID has few of. Extensions are renamed to sit under it."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                identityField(.displayName, hint: L("Name on the Home Screen"))
                HStack(spacing: 12) {
                    identityField(.version, hint: "1.0")
                    identityField(.build, hint: "1")
                }

                if !store.config.pinnedIdentity.isEmpty {
                    Button {
                        for field in AppConfig.IdentityField.allCases { store.pin(field, false) }
                        applyIdentity(from: snapshot)
                        note = L("Identity reset to the build's own values.")
                    } label: {
                        Label(L("Use the build's values"), systemImage: "arrow.uturn.backward")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    /// One identity field. Typing pins it; the arrow restores the build's value.
    private func identityField(_ field: AppConfig.IdentityField, hint: String,
                               monospaced: Bool = false) -> some View {
        let pinned = store.isPinned(field)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(field.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if pinned {
                    Text(L("yours"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.accent2)
                }
                Spacer(minLength: 0)
                if pinned {
                    Button {
                        store.pin(field, false)
                        applyIdentity(from: snapshot)
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            TextField(hint, text: Binding(
                get: { store.config[field] },
                set: { value in
                    store.config[field] = value
                    // Only a real edit pins it; the build's own values are
                    // written with `applyingSnapshot` up.
                    if !applyingSnapshot, value != buildValue(field) {
                        store.pin(field, true)
                    }
                }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(monospaced ? .subheadline.monospaced() : .subheadline)
                .fieldBackground()
        }
    }

    private func buildValue(_ field: AppConfig.IdentityField) -> String {
        switch field {
        case .bundleIdentifier: return snapshot.bundleID
        case .displayName:      return snapshot.name
        case .version:          return snapshot.version
        case .build:            return snapshot.build
        }
    }

    // MARK: Info.plist

    private var plistCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                header(L("Info.plist"), systemImage: "list.bullet.rectangle")
                Text(L("Keys the build already has, and any you add. Everything here ends up as a top-level key in the app's Info.plist."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !snapshot.plist.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(snapshot.plist, id: \.key) { entry in
                                Button {
                                    adoptPlistEntry(entry)
                                } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(entry.key)
                                                .font(.caption.monospaced())
                                            Text(entry.text)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                                .lineLimit(2)
                                        }
                                        Spacer(minLength: 4)
                                        Image(systemName: isEdited(entry.key)
                                              ? "pencil.circle.fill" : "plus.circle")
                                            .font(.footnote)
                                            .foregroundStyle(isEdited(entry.key) ? Theme.accent2 : .secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text(L("In the build (%ld keys)", snapshot.plist.count))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                editRows($store.config.plistEdits, addLabel: L("Add a key"), plistKeys: true)
            }
        }
    }

    /// True when this key is already in the configuration's edit list.
    private func isEdited(_ key: String) -> Bool {
        store.config.plistEdits.contains { $0.key == key }
    }

    /// Tapping a key in the build adds it to the edit list, prefilled — so
    /// changing something is one tap, not a retyped key.
    private func adoptPlistEntry(_ entry: (key: String, kind: PlistEdit.Kind, text: String)) {
        if let index = store.config.plistEdits.firstIndex(where: { $0.key == entry.key }) {
            store.config.plistEdits.remove(at: index)
            note = L("%@ set back to the build's value.", entry.key)
            return
        }
        store.config.plistEdits.append(PlistEdit(key: entry.key, kind: entry.kind, value: entry.text))
        note = L("%@ will be written as it is now — change the value below.", entry.key)
    }

    // MARK: Entitlements

    private var entitlementsCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                header(L("Entitlements"), systemImage: "checkmark.shield")
                Text(L("Added to the app's archived entitlements file. The profile your Apple ID issues decides what's actually granted — asking for something it doesn't allow fails the install rather than granting it."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !snapshot.entitlements.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(snapshot.entitlements, id: \.key) { entry in
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(entry.key)
                                            .font(.caption.monospaced())
                                        Text(entry.text)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(2)
                                    }
                                    Spacer(minLength: 4)
                                }
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text(L("In the build's profile (%ld)", snapshot.entitlements.count))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                editRows($store.config.entitlements, addLabel: L("Add an entitlement"), plistKeys: false)
            }
        }
    }

    // MARK: The editor shared by both lists

    private func editRows(_ edits: Binding<[PlistEdit]>, addLabel: String,
                          plistKeys: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(edits) { $edit in
                PlistEditRow(edit: $edit, plistKeys: plistKeys) {
                    edits.wrappedValue.removeAll { $0.id == edit.id }
                }
            }
            Button {
                edits.wrappedValue.append(PlistEdit(key: "", kind: .string, value: ""))
            } label: {
                Label(addLabel, systemImage: "plus.circle.fill")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: Extensions

    private var extensionsCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                header(L("Extensions"), systemImage: "puzzlepiece.extension")
                if snapshot.extensions.isEmpty {
                    Text(L("The imported .ipa lists no extension."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.extensions, id: \.self) { name in
                        Toggle(isOn: Binding(
                            get: { !store.config.disabledExtensions.contains(name) },
                            set: { keep in
                                var list = store.config.disabledExtensions
                                list.removeAll { $0 == name }
                                if !keep { list.append(name) }
                                store.config.disabledExtensions = list
                            })) {
                            Text(name)
                                .font(.subheadline)
                                .lineLimit(1)
                        }
                        .disabled(store.config.stripExtensions)
                    }
                }
                Toggle(isOn: $store.config.stripExtensions) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Remove all extensions"))
                            .font(.subheadline)
                        Text(L("Widgets, share sheets and keyboards go with them."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $store.config.stripWatchApp) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Remove the Watch app"))
                            .font(.subheadline)
                        Text(L("The iPhone app installs without its watchOS companion."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Tweaks and injectors

    private var tweaksCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    header(L("Tweaks & injectors"), systemImage: "syringe")
                    Spacer()
                    Button {
                        showTweakPicker = true
                    } label: {
                        Label(L("Add tweak"), systemImage: "plus")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                }

                if store.config.tweaks.isEmpty {
                    Text(L("A .dylib or a .deb added here is unpacked into the app's Frameworks folder and loaded by its main executable, the way a jailbreak tweak is. Its dependencies are read when it's added, so the framework it hooks with is loaded too."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(store.config.tweaks) { tweak in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: tweak.isDeb ? "shippingbox.fill" : "doc.fill")
                                .font(.footnote)
                                .foregroundStyle(Theme.accent2)
                            Text(tweak.name)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Button(role: .destructive) {
                                store.removeTweak(tweak.id)
                            } label: {
                                Image(systemName: "trash").font(.footnote)
                            }
                            .buttonStyle(.borderless)
                        }
                        HStack(spacing: 6) {
                            Text(tweak.isDeb ? L(".deb package") : L(".dylib"))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            if let kind = tweak.requiresInjector {
                                Text(store.injector(for: kind) == nil
                                     ? L("needs %@ (not added)", kind.title)
                                     : L("uses %@", kind.title))
                                    .font(.caption2)
                                    .foregroundStyle(store.injector(for: kind) == nil ? .orange : .secondary)
                            }
                        }
                        Toggle(isOn: Binding(get: { tweak.weak },
                                             set: { store.setWeak($0, for: tweak.id) })) {
                            Text(L("Optional (load only if present)"))
                                .font(.caption)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    }
                    .padding(.vertical, 4)
                    Divider().opacity(0.15)
                }

                // The frameworks themselves live in the same card: a tweak
                // without its injector doesn't launch, so they're one decision.
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Injection frameworks"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(TweakInjectorKind.allCases) { kind in
                        injectorRow(kind)
                    }
                    if !store.missingInjectors.isEmpty {
                        Text(L("Needed by an added tweak: %@.", store.missingInjectors.map(\.title).joined(separator: ", ")))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.top, 2)

                Text(L("Tweaks have to be built for this iPhone: arm64, iOS 17.4 or later. Rootless packages work, since only their libraries are taken. Injecting needs room in the app's Mach-O header, which Xcode builds have."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func injectorRow(_ kind: TweakInjectorKind) -> some View {
        let entry = InjectorCatalog.entry(for: kind)
        let installed = store.injector(for: kind)
        let busy = store.injectorStatus[kind] == L("Downloading…")
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(.subheadline)
                if let installed {
                    Text(installed.fileName)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else if let status = store.injectorStatus[kind] {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text(entry.note)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if busy {
                ProgressView().controlSize(.small)
            } else if installed != nil {
                Button(role: .destructive) {
                    store.removeInjector(kind)
                    store.clearInjectorStatus(kind)
                } label: {
                    Image(systemName: "trash").font(.footnote)
                }
                .buttonStyle(.borderless)
            } else {
                HStack(spacing: 8) {
                    if entry.source != nil {
                        Button(L("Get")) {
                            Task { await store.downloadInjector(kind) }
                        }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.borderless)
                    }
                    Button(L("Add")) { injectedFor = kind }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: Backup

    private var backupCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    if let data = store.exportData() {
                        let url = FileManager.default.temporaryDirectory
                            .appendingPathComponent("app-config.json")
                        try? data.write(to: url)
                        share(url)
                    }
                } label: {
                    Label(L("Export"), systemImage: "square.and.arrow.up")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    showConfigImporter = true
                } label: {
                    Label(L("Import"), systemImage: "square.and.arrow.down")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            Button(role: .destructive) {
                store.reset()
                note = L("Configuration cleared.")
            } label: {
                Label(L("Clear the configuration"), systemImage: "arrow.uturn.backward")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!store.config.isActive)
        }
    }

    // MARK: Pieces

    private func header(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func share(_ url: URL) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.keyWindow?.rootViewController else { return }
        var controller = root
        while let presented = controller.presentedViewController { controller = presented }
        controller.present(UIActivityViewController(activityItems: [url],
                                                    applicationActivities: nil),
                           animated: true)
    }
}

private extension UIWindowScene {
    var keyWindow: UIWindow? { windows.first { $0.isKeyWindow } }
}

// MARK: - One plist edit

/// A key, its type, and its value — with the Apple key catalogue behind the
/// field for completions, and the editor the type calls for.
private struct PlistEditRow: View {
    @Binding var edit: PlistEdit
    /// True for `Info.plist` keys, which have the catalogue; entitlements don't.
    var plistKeys: Bool
    var onDelete: () -> Void

    @FocusState private var keyFocused: Bool

    private var spec: PlistKeySpec? { PlistCatalog.spec(for: edit.key.trimmed) }

    /// Keys worth offering under the field: what's been typed, minus the one
    /// that's already exactly there.
    private var suggestions: [PlistKeySpec] {
        guard plistKeys else { return [] }
        let query = edit.key.trimmed
        guard spec == nil else { return [] }
        let matches = PlistCatalog.matching(query)
        return Array(matches.prefix(query.isEmpty ? 6 : 8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(plistKeys ? "CFBundle…" : "com.apple.developer…", text: $edit.key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
                    .focused($keyFocused)
                Picker("", selection: $edit.kind) {
                    ForEach(PlistEdit.Kind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash").font(.footnote)
                }
                .buttonStyle(.borderless)
            }

            if keyFocused, !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(suggestions) { suggestion in
                        Button {
                            edit.key = suggestion.key
                            edit.kind = suggestion.kind
                            if let first = suggestion.values.first, edit.value.isEmpty {
                                edit.value = first
                            }
                            keyFocused = false
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(suggestion.key)
                                    .font(.caption.monospaced())
                                Text(suggestion.summary)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.05)))
            }

            if let spec {
                Text(spec.summary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            valueEditor
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.white.opacity(0.05)))
        .onChange(of: edit.key) { _, key in
            // Picking a known key also picks the editor it needs.
            guard let found = PlistCatalog.spec(for: key.trimmed), found.kind != edit.kind else { return }
            edit.kind = found.kind
        }
    }

    @ViewBuilder
    private var valueEditor: some View {
        // A documented enumeration gets a menu of its values; anything else an
        // editor for its type.
        if let spec, !spec.values.isEmpty, edit.kind == .string || edit.kind == .array {
            if edit.kind == .array {
                listPicker(spec.values)
            } else {
                Picker(L("Value"), selection: $edit.value) {
                    ForEach(spec.values, id: \.self) { Text($0).tag($0) }
                    if !spec.values.contains(edit.value) {
                        Text(edit.value.isEmpty ? L("Not set") : edit.value).tag(edit.value)
                    }
                }
                .pickerStyle(.menu)
                .font(.footnote)
            }
        } else {
            switch edit.kind {
            case .boolean:
                Toggle(isOn: Binding(get: { (edit.value as NSString).boolValue },
                                     set: { edit.value = $0 ? "true" : "false" })) {
                    Text(L("On")).font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            case .array:
                TextField(L("a, b, c"), text: $edit.value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote)
                    .fieldBackground()
            case .integer:
                TextField("0", text: $edit.value)
                    .keyboardType(.numbersAndPunctuation)
                    .font(.footnote)
                    .fieldBackground()
            case .string:
                TextField(L("Value"), text: $edit.value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote)
                    .fieldBackground()
            }
        }
    }

    /// The array editor for keys whose values Apple enumerates: tap to add or
    /// drop a value from the comma-separated list.
    private func listPicker(_ values: [String]) -> some View {
        let chosen = edit.value.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(values, id: \.self) { value in
                Button {
                    var list = chosen
                    if let index = list.firstIndex(of: value) {
                        list.remove(at: index)
                    } else {
                        list.append(value)
                    }
                    edit.value = list.joined(separator: ", ")
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: chosen.contains(value) ? "checkmark.circle.fill" : "circle")
                            .font(.caption)
                            .foregroundStyle(chosen.contains(value) ? Theme.accent2 : .secondary)
                        Text(value)
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
