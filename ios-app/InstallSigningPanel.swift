import SwiftUI
import UniformTypeIdentifiers

/// A common iOS capability, as the keys that grant it.
///
/// A capability is not a switch the app can flip on its own: it writes the
/// plist key and the entitlement, and the profile Apple issues still decides
/// what's actually granted. The panel says so rather than pretending.
enum AppCapability: String, CaseIterable, Identifiable {
    case documentBrowser
    case backgroundAudio
    case backgroundLocation
    case increasedMemory
    case wifiInfo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .documentBrowser:    return L("Document browser")
        case .backgroundAudio:    return L("Background audio")
        case .backgroundLocation: return L("Background location")
        case .increasedMemory:    return L("Increased memory limit")
        case .wifiInfo:           return L("Wi-Fi network info")
        }
    }

    var detail: String {
        switch self {
        case .documentBrowser:    return L("Files app access: UIFileSharingEnabled and LSSupportsOpeningDocumentsInPlace.")
        case .backgroundAudio:    return L("Keeps playing when backgrounded: UIBackgroundModes gains audio.")
        case .backgroundLocation: return L("Location updates while backgrounded: UIBackgroundModes gains location.")
        case .increasedMemory:    return L("Raises the memory ceiling on devices that allow it (entitlement).")
        case .wifiInfo:           return L("Reads the connected network's SSID (entitlement).")
        }
    }

    var icon: String {
        switch self {
        case .documentBrowser:    return "folder.badge.gearshape"
        case .backgroundAudio:    return "waveform"
        case .backgroundLocation: return "location.circle"
        case .increasedMemory:    return "memorychip"
        case .wifiInfo:           return "wifi"
        }
    }

    /// `Info.plist` keys, and whether they're a list the value joins.
    var plistKeys: [(key: String, value: String, isArray: Bool)] {
        switch self {
        case .documentBrowser:
            return [("UIFileSharingEnabled", "true", false),
                    ("LSSupportsOpeningDocumentsInPlace", "true", false)]
        case .backgroundAudio:
            return [("UIBackgroundModes", "audio", true)]
        case .backgroundLocation:
            return [("UIBackgroundModes", "location", true)]
        default:
            return []
        }
    }

    var entitlementKeys: [String] {
        switch self {
        case .increasedMemory: return ["com.apple.developer.kernel.increased-memory-limit"]
        case .wifiInfo:        return ["com.apple.developer.networking.wifi-info"]
        default:               return []
        }
    }
}

extension AppConfigStore {

    /// True when every key this capability writes is already in the
    /// configuration — entries the user wrote by hand count too.
    func isEnabled(_ capability: AppCapability) -> Bool {
        for entry in capability.plistKeys {
            guard let edit = config.plistEdits.first(where: { $0.key == entry.key }),
                  edit.value.contains(entry.value) else { return false }
        }
        for key in capability.entitlementKeys where !config.entitlements.contains(where: { $0.key == key }) {
            return false
        }
        return true
    }

    /// Adds the keys the capability needs, or takes back exactly the ones it
    /// wrote — a list value is removed from the list, not the whole list.
    func set(_ enabled: Bool, for capability: AppCapability) {
        for entry in capability.plistKeys {
            if enabled {
                upsertPlist(key: entry.key, value: entry.value, isArray: entry.isArray)
            } else {
                removePlistValue(key: entry.key, value: entry.value, isArray: entry.isArray)
            }
        }
        for key in capability.entitlementKeys {
            if enabled {
                if !config.entitlements.contains(where: { $0.key == key }) {
                    config.entitlements.append(PlistEdit(key: key, kind: .boolean, value: "true"))
                }
            } else {
                config.entitlements.removeAll { $0.key == key }
            }
        }
    }

    private func upsertPlist(key: String, value: String, isArray: Bool) {
        guard let index = config.plistEdits.firstIndex(where: { $0.key == key }) else {
            config.plistEdits.append(PlistEdit(key: key,
                                              kind: isArray ? .array : .boolean,
                                              value: value))
            return
        }
        guard isArray else { return }
        var items = config.plistEdits[index].value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !items.contains(value) else { return }
        items.append(value)
        config.plistEdits[index].value = items.joined(separator: ", ")
    }

    private func removePlistValue(key: String, value: String, isArray: Bool) {
        guard let index = config.plistEdits.firstIndex(where: { $0.key == key }) else { return }
        guard isArray else {
            config.plistEdits.remove(at: index)
            return
        }
        var items = config.plistEdits[index].value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != value }
        if items.isEmpty {
            config.plistEdits.remove(at: index)
        } else {
            config.plistEdits[index].value = items.joined(separator: ", ")
        }
    }
}

/// The expandable signing configuration under the install menu: identity,
/// plist and entitlement editing, capabilities, the libraries a build loads, and
/// the tweaks patched into it with the injectors they need.
struct InstallSigningPanel: View {
    @ObservedObject private var config = AppConfigStore.shared
    @ObservedObject private var library = TweakLibrary.shared
    @EnvironmentObject private var loc: Localizer

    @State private var showAppConfig = false
    @State private var showBrowser = false
    @State private var showLibrary = false
    @State private var pendingInjectorKind: TweakInjectorKind?
    @State private var showInjectorImporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            identity
            plistRows
            capabilities
            libraries
            tweaks
            injectors
        }
        .sheet(isPresented: $showAppConfig) { AppConfigView() }
        .sheet(isPresented: $showBrowser) { TweakBrowserView(store: config) }
        .sheet(isPresented: $showLibrary) { TweakLibraryView() }
        .sheet(isPresented: $showInjectorImporter) {
            FileImporterRepresentableView(allowedContentTypes: [.dylib]) { urls in
                guard let kind = pendingInjectorKind, let url = urls.first else { return }
                _ = config.addInjector(kind, from: url)
                pendingInjectorKind = nil
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Identity

    private var identity: some View {
        VStack(alignment: .leading, spacing: 8) {
            group(L("Identity"), systemImage: "person.text.rectangle")
            field(L("App name"), text: Binding(
                get: { config.config.displayName },
                set: { config.config.displayName = $0 }))
            field(L("Bundle ID"), text: Binding(
                get: { config.config.bundleIdentifier },
                set: { config.config.bundleIdentifier = $0 }), mono: true)
            Text(L("Leave a field empty to keep the build's own value. These apply to the .ipa being signed — a preset build is installed exactly as its maintainers published it."))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(_ title: String, text: Binding<String>, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField(title, text: text)
                .font(mono ? .caption.monospaced() : .subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .fieldBackground()
        }
    }

    // MARK: Info.plist and entitlements

    private var plistRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            group(L("Info.plist and entitlements"), systemImage: "list.bullet.rectangle")
            summaryRow(icon: "doc.text",
                       title: L("Info.plist"),
                       detail: config.config.plistEdits.isEmpty
                             ? L("No keys added")
                             : L("%d key(s) added", config.config.plistEdits.count))
            summaryRow(icon: "checkmark.seal",
                       title: L("Entitlements"),
                       detail: config.config.entitlements.isEmpty
                             ? L("None declared")
                             : L("%d entitlement(s)", config.config.entitlements.count))
            Button { showAppConfig = true } label: {
                Label(L("Edit keys and entitlements"), systemImage: "slider.horizontal.3")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func summaryRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(Theme.accent2)
                .frame(width: 18)
            Text(title)
                .font(.caption.weight(.semibold))
            Spacer(minLength: 6)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    // MARK: Capabilities

    private var capabilities: some View {
        VStack(alignment: .leading, spacing: 8) {
            group(L("Capabilities"), systemImage: "switch.2")
            ForEach(AppCapability.allCases) { capability in
                Toggle(isOn: Binding(get: { config.isEnabled(capability) },
                                     set: { config.set($0, for: capability) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(capability.title)
                            .font(.caption.weight(.semibold))
                        Text(capability.detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            Text(L("A capability writes the plist key and entitlement the app expects. Whether iOS grants it is still down to the provisioning profile your Apple ID issues."))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Frameworks and libraries

    private var libraries: some View {
        VStack(alignment: .leading, spacing: 8) {
            group(L("Frameworks and dylibs"), systemImage: "shippingbox")
            Text(config.config.tweaks.isEmpty
                 ? L("Nothing injected yet.")
                 : L("%d library package(s) injected.", config.config.tweaks.count))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button { showLibrary = true } label: {
                    Label(L("Tweak storage"), systemImage: "tray.full")
                }
                .buttonStyle(SecondaryButtonStyle())
                Button { showBrowser = true } label: {
                    Label(L("Browse"), systemImage: "magnifyingglass")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            if library.items.count > 0 {
                Text(L("%d tweak(s) kept in storage, ready to add.", library.items.count))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Tweaks

    private var tweaks: some View {
        VStack(alignment: .leading, spacing: 8) {
            group(L("Tweaks"), systemImage: "syringe")
            if config.config.tweaks.isEmpty {
                Text(L("A .dylib or .deb added here is unpacked into the app's Frameworks folder and loaded by its main executable."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(config.config.tweaks) { tweak in
                HStack(spacing: 8) {
                    Image(systemName: tweak.isDeb ? "shippingbox.fill" : "doc.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.accent2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tweak.name)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            if let version = tweak.versionText {
                                Text(version)
                            }
                            if let host = tweak.repositoryHost {
                                Text("·")
                                Text(host)
                            }
                            if let kind = tweak.requiresInjector {
                                Text("·")
                                Text(config.injector(for: kind) == nil
                                     ? L("needs %@", kind.title)
                                     : L("uses %@", kind.title))
                                    .foregroundStyle(config.injector(for: kind) == nil ? .orange : .secondary)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button(role: .destructive) {
                        config.removeTweak(tweak.id)
                    } label: {
                        Image(systemName: "trash").font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: Injectors

    private var injectors: some View {
        VStack(alignment: .leading, spacing: 8) {
            group(L("Injection frameworks"), systemImage: "arrow.down.to.line")
            ForEach(TweakInjectorKind.allCases) { kind in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kind.title)
                            .font(.caption.weight(.semibold))
                        if let installed = config.injector(for: kind) {
                            Text(installed.fileName)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        } else if let status = config.injectorStatus[kind] {
                            Text(status)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(L("Not added"))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 6)
                    if config.injector(for: kind) != nil {
                        Button(role: .destructive) {
                            config.removeInjector(kind)
                        } label: {
                            Image(systemName: "trash").font(.caption)
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Button {
                            Task { await config.downloadInjector(kind) }
                        } label: {
                            Image(systemName: "arrow.down.circle").font(.footnote)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L("Download %@", kind.title))
                        Button {
                            pendingInjectorKind = kind
                            showInjectorImporter = true
                        } label: {
                            Image(systemName: "folder.badge.plus").font(.footnote)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L("Add %@ from a file", kind.title))
                    }
                }
                .padding(.vertical, 2)
            }
            if !config.missingInjectors.isEmpty {
                Text(L("Needed by an added tweak: %@.", config.missingInjectors.map(\.title).joined(separator: ", ")))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L("ElleKit and Substitute can be downloaded; CydiaSubstrate and libhooker are closed, so they're added from a copy you have. A tweak that names one in its dependencies gets it loaded beside it."))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func group(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}
