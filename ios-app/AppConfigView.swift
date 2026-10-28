import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A compiled tweak. Not declared in Info.plist: the picker only needs the
    /// extension to let a `.dylib` be chosen.
    static let dylib = UTType(filenameExtension: "dylib") ?? .data
}

/// What SideInstaller should change about the custom `.ipa` before signing it:
/// its identity, its nested bundles, and the tweaks it loads.
///
/// Shown from the Install screen's Advanced section; the values are kept until
/// they're cleared, so the same build is prepared each time it's installed.
struct AppConfigView: View {
    @EnvironmentObject private var loc: Localizer
    @ObservedObject private var store = AppConfigStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showTweakPicker = false
    @State private var tweakError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    introCard
                    identityCard
                    structureCard
                    tweaksCard
                    resetCard
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
                FileImporterRepresentableView(allowedContentTypes: [.dylib], allowsMultipleSelection: true) { urls in
                    guard !urls.isEmpty else { return }
                    let result = store.addTweaks(urls)
                    tweakError = result.failed.isEmpty ? nil
                        : L("Couldn't add %@.", result.failed.joined(separator: ", "))
                }
                .ignoresSafeArea()
            }
        }
    }

    // MARK: Intro

    private var introCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Applied when the custom .ipa is signed"))
                    .font(.headline)
                Text(L("SideInstaller rewrites the archive — renaming it, dropping what you remove here, and loading the tweaks you add — then signs the result with your Apple ID. The imported file is replaced, so a refresh later reinstalls the same configured build."))
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
                Label(L("Identity"), systemImage: "app.badge")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

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
            }
        }
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

    // MARK: Structure

    private var structureCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 14) {
                Label(L("Structure"), systemImage: "square.stack.3d.up")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Toggle(isOn: $store.config.stripExtensions) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Remove app extensions"))
                            .font(.subheadline)
                        Text(L("Widgets, share sheets and keyboards go with them. Helps when an extension is what signing trips over."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle(isOn: $store.config.stripWatchApp) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Remove the Watch app"))
                            .font(.subheadline)
                        Text(L("The iPhone app installs without its watchOS companion."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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
                    Label(L("Tweaks"), systemImage: "syringe")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
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
                    Text(L("No tweaks. A .dylib added here is copied into the app's Frameworks folder and loaded by its main executable, the same way a jailbreak tweak is."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(store.config.tweaks) { tweak in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "shippingbox.fill")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.accent2)
                                Text(tweak.name)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Button(role: .destructive) {
                                    store.removeTweak(tweak.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.footnote)
                                }
                                .buttonStyle(.borderless)
                            }
                            Text(tweak.loadPath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
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

                Text(L("Tweaks have to be built for this iPhone: arm64 or arm64e, iOS 17.4 or later. Injecting one needs room in the app's Mach-O header, which Xcode builds have."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Reset

    private var resetCard: some View {
        Button(role: .destructive) {
            store.reset()
        } label: {
            Label(L("Clear the configuration"), systemImage: "arrow.uturn.backward")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!store.config.isActive)
    }
}
