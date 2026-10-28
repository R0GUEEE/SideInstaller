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

/// The full configuration toolkit for the custom `.ipa`: its identity, any
/// `Info.plist` key, its entitlements, which extensions survive, and the tweaks
/// — `.dylib` or `.deb` — loaded into it.
///
/// Shown from the Install screen's Advanced section. Values are kept until
/// they're cleared, so the same build is prepared the same way each time.
struct AppConfigView: View {
    @EnvironmentObject private var loc: Localizer
    @ObservedObject private var store = AppConfigStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showTweakPicker = false
    @State private var showConfigImporter = false
    @State private var tweakError: String?
    @State private var injectedFor: TweakInjectorKind?
    @State private var extensions: [String] = []
    @State private var importNote: String?

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
                    injectorsCard
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
                    tweakError = result.failed.isEmpty ? nil
                        : L("Couldn't add %@.", result.failed.joined(separator: ", "))
                }
                .ignoresSafeArea()
            }
            .sheet(item: $injectedFor) { kind in
                FileImporterRepresentableView(allowedContentTypes: [.dylib]) { urls in
                    guard let url = urls.first else { return }
                    if !store.addInjector(kind, from: url) {
                        tweakError = L("That file couldn't be added as %@.", kind.title)
                    }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showConfigImporter) {
                FileImporterRepresentableView(allowedContentTypes: [.json]) { urls in
                    guard let url = urls.first,
                          let data = try? Data(contentsOf: url) else { return }
                    importNote = store.importData(data)
                        ? L("Configuration imported.")
                        : L("That isn't a configuration file this version understands.")
                }
                .ignoresSafeArea()
            }
            .onAppear(perform: loadExtensions)
            .onChange(of: store.config.tweaks.count) { _, _ in loadExtensions() }
        }
    }

    /// The extensions of the build in the custom slot, so each can be dropped
    /// by name. Read lazily, since it walks the archive.
    private func loadExtensions() {
        guard let url = IPALibrary.customImport()?.url else {
            if !extensions.isEmpty { extensions = [] }
            return
        }
        let names = IPAInspector.extensionNames(in: url)
        if names != extensions { extensions = names }
    }

    // MARK: Intro

    private var introCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Applied when the custom .ipa is signed"))
                    .font(.headline)
                Text(L("SideInstaller rewrites the archive — renaming it, editing its plists, dropping extensions, loading tweaks — then signs the result with your Apple ID. The imported file is replaced, so a refresh later reinstalls the same configured build."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            }
        }
    }

    // MARK: Identity

    private var identityCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 14) {
                header(L("Identity"), systemImage: "app.badge")

                Button {
                    let imported = store.importFromCurrentIPA()
                    importNote = imported
                        ? L("Filled in from the imported .ipa.")
                        : L("Import a .ipa on the Install tab first.")
                } label: {
                    Label(L("Import from the .ipa"), systemImage: "square.and.arrow.down.on.square")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                field(L("Bundle ID"), hint: "com.example.app",
                      text: $store.config.bundleIdentifier)
                Text(L("A new bundle ID installs alongside the original and registers its own App ID, which a free Apple ID has few of. Extensions are renamed to sit under it."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                field(L("Display name"), hint: L("As it appears on the Home Screen"),
                      text: $store.config.displayName)
                HStack(spacing: 12) {
                    field(L("Version"), hint: "1.0", text: $store.config.version)
                    field(L("Build"), hint: "1", text: $store.config.build)
                }
                if let importNote {
                    Text(importNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Plists

    private var plistCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                header(L("Info.plist"), systemImage: "list.bullet.rectangle")
                Text(L("Top-level keys added or replaced in the app's Info.plist — a URL scheme, a supported device, `UIFileSharingEnabled`, anything the build ships with."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                editRows($store.config.plistEdits, addLabel: L("Add a key"))
            }
        }
    }

    private var entitlementsCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                header(L("Entitlements"), systemImage: "checkmark.shield")
                Text(L("Written into the app's archived entitlements file. The profile your Apple ID issues decides what's actually granted — asking for something it doesn't allow fails the install rather than granting it."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                editRows($store.config.entitlements, addLabel: L("Add an entitlement"))
            }
        }
    }

    /// The editor shared by the two plist lists: key, type, value, remove.
    private func editRows(_ edits: Binding<[PlistEdit]>, addLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(edits) { $edit in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField(L("Key"), text: $edit.key)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.footnote.monospaced())
                        Picker("", selection: $edit.kind) {
                            ForEach(PlistEdit.Kind.allCases) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        Button(role: .destructive) {
                            edits.wrappedValue.removeAll { $0.id == edit.id }
                        } label: {
                            Image(systemName: "trash").font(.footnote)
                        }
                        .buttonStyle(.borderless)
                    }
                    valueField(for: $edit)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.05)))
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

    @ViewBuilder
    private func valueField(for edit: Binding<PlistEdit>) -> some View {
        switch edit.wrappedValue.kind {
        case .boolean:
            Toggle(isOn: Binding(get: { (edit.wrappedValue.value as NSString).boolValue },
                                 set: { edit.wrappedValue.value = $0 ? "true" : "false" })) {
                Text(L("On"))
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
        default:
            TextField(edit.wrappedValue.kind == .array ? L("a, b, c") : L("Value"),
                      text: edit.value)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.footnote)
                .fieldBackground()
        }
    }

    // MARK: Extensions

    private var extensionsCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                header(L("Extensions"), systemImage: "puzzlepiece.extension")
                if extensions.isEmpty {
                    Text(L("The imported .ipa lists no extension."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(extensions, id: \.self) { name in
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

    // MARK: Tweaks

    private var tweaksCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    header(L("Tweaks"), systemImage: "syringe")
                    Spacer()
                    Button {
                        showTweakPicker = true
                    } label: {
                        Label(L("Add"), systemImage: "plus")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                }

                if store.config.tweaks.isEmpty {
                    Text(L("No tweaks. A .dylib or a .deb added here is unpacked into the app's Frameworks folder and loaded by its main executable, the way a jailbreak tweak is."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
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
                                    Text(L("needs %@", kind.title))
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
                        if tweak.id != store.config.tweaks.last?.id { Divider().opacity(0.15) }
                    }
                }

                if let tweakError {
                    Text(tweakError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Text(L("Tweaks have to be built for this iPhone: arm64, iOS 17.4 or later. Rootless packages (`/var/jb`) work because only their libraries are taken. Injecting needs room in the app's Mach-O header, which Xcode builds have."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Injectors

    private var injectorsCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                header(L("Injectors"), systemImage: "powerplug")
                Text(L("The framework a tweak hooks with. SideInstaller can't ship these, so add the .dylib from a copy you have. A package's dependencies pick which one is loaded."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(TweakInjectorKind.allCases) { kind in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(kind.title)
                                .font(.subheadline)
                            if let injector = store.injector(for: kind) {
                                Text(injector.fileName)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            } else {
                                Text(L("Not added"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 4)
                        if store.injector(for: kind) != nil {
                            Button(role: .destructive) {
                                store.removeInjector(kind)
                            } label: {
                                Image(systemName: "trash").font(.footnote)
                            }
                            .buttonStyle(.borderless)
                        } else {
                            Button(L("Add")) { injectedFor = kind }
                                .font(.footnote.weight(.semibold))
                                .buttonStyle(.borderless)
                        }
                    }
                    if kind != TweakInjectorKind.allCases.last { Divider().opacity(0.15) }
                }
                if !store.missingInjectors.isEmpty {
                    Text(L("Needed by an added tweak: %@.", store.missingInjectors.map(\.title).joined(separator: ", ")))
                        .font(.caption)
                        .foregroundStyle(.orange)
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

    /// One text field with a clear button, styled like the app's other fields.
    private func field(_ label: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField(hint, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.subheadline)
                if !text.wrappedValue.isEmpty {
                    Button {
                        text.wrappedValue = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .fieldBackground()
        }
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

// MARK: - Starting from the imported build

extension AppConfigStore {
    /// Fills the identity fields from the app that's currently imported, so a
    /// change starts from what the build already says.
    /// Reads the app currently in the custom slot, so a change starts from
    /// what the build already says.
    @discardableResult
    func importFromCurrentIPA() -> Bool {
        guard let entry = IPALibrary.customImport(),
              let info = IPALibrary.appInfo(at: entry.url) else { return false }
        config.bundleIdentifier = info.bundleID
        config.displayName = info.name
        config.version = info.version ?? ""
        return true
    }

}
