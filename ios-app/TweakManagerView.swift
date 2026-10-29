import SwiftUI
import UIKit

/// What's been injected into the apps SideInstaller installed, and how to take it
/// back out.
///
/// Read from the stored `.ipa` rather than from the device: the binary inside the
/// cached build is the one that was signed, and its load commands list every
/// library the app pulls in. Anything that isn't Apple's is a tweak, a framework
/// or an injector.
struct TweakManagerView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var engine: Engine

    /// One stored build and the libraries it loads.
    struct Stored: Identifiable {
        let build: IPACache.Cached
        let libraries: [String]
        let injected: Bool

        var id: String { build.bundleID }
        /// The names that could be removed: `.dylib` leaves only.
        var removable: [String] { libraries.filter { $0.lowercased().hasSuffix(".dylib") } }
    }

    @State private var items: [Stored] = []
    @State private var isReading = false
    @State private var pendingStrip: Stored?
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                header.cascadeItem(0)
                if isReading {
                    ProgressView().padding(.top, 20)
                } else if items.isEmpty {
                    emptyCard.cascadeItem(1)
                } else {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        card(item).cascadeItem(min(index + 1, 6))
                    }
                }
            }
            .padding(20)
            .pageColumn()
        }
        .background(AppBackground())
        .toolbar { settingsToolbarItem(isPresented: $showSettings) }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .task { await load() }
        .confirmationDialog(L("Reinstall without these libraries?"),
                            isPresented: Binding(get: { pendingStrip != nil },
                                                 set: { if !$0 { pendingStrip = nil } }),
                            presenting: pendingStrip) { item in
            Button(L("Remove them and reinstall"), role: .destructive) {
                strip(item)
                pendingStrip = nil
            }
            Button(L("Cancel"), role: .cancel) { pendingStrip = nil }
        } message: { item in
            Text(L("%@ keeps its data: the build is signed again without the libraries, and installed over itself.", item.build.displayName))
        }
    }

    private var header: some View {
        BrandHeader(icon: "syringe", title: L("Injected libraries")) {
            if !items.isEmpty {
                StatusPill(text: L("%ld build(s)", items.count),
                           systemImage: "shippingbox", color: Theme.accent2)
            }
        }
    }

    private var emptyCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Nothing to inspect yet"))
                    .font(.headline)
                Text(L("This reads the builds SideInstaller keeps — install something, then its libraries appear here. A tweak shows up as a .dylib the app loads which isn't Apple's."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func card(_ item: Stored) -> some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.injected ? "syringe.fill" : "app.badge.checkmark")
                        .font(.title3)
                        .foregroundStyle(item.injected ? Theme.accent2 : .green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.build.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(item.build.bundleID)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                if item.libraries.isEmpty {
                    Text(L("Links nothing but Apple's frameworks."))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(item.libraries, id: \.self) { library in
                        HStack(spacing: 6) {
                            Image(systemName: library.lowercased().hasSuffix(".dylib")
                                  ? "puzzlepiece.extension" : "shippingbox")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(library)
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                    }
                }
                if !item.removable.isEmpty {
                    Button {
                        pendingStrip = item
                    } label: {
                        Label(L("Remove and reinstall"), systemImage: "scissors")
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(engine.isRunning)
                }
            }
        }
    }

    private func load() async {
        guard items.isEmpty else { return }
        isReading = true
        let builds = IPACache.all()
        let read = await Task.detached(priority: .userInitiated) { () -> [Stored] in
            var out: [Stored] = []
            for build in builds {
                guard let archive = IPALibrary.archiveFiles(at: build.url) else { continue }
                guard let plistEntry = archive.first(where: {
                    $0.path.hasSuffix("/Info.plist") && $0.path.contains("Payload/")
                }) else { continue }
                let bundlePath: String = String(plistEntry.path.dropLast("/Info.plist".count))
                guard let raw = IPALibrary.contents(of: plistEntry, in: build.url),
                      let parsed = try? PropertyListSerialization.propertyList(from: raw, format: nil),
                      let plist = parsed as? [String: Any] else { continue }
                let folderName: String = (bundlePath as NSString).lastPathComponent
                let executable: String = (plist["CFBundleExecutable"] as? String) ?? folderName
                let binaryPath: String = bundlePath + "/" + executable
                guard let binaryEntry = archive.first(where: { $0.path == binaryPath }),
                      let binary = IPALibrary.contents(of: binaryEntry, in: build.url, max: 64 << 20)
                else { continue }
                let libraries = IPAPatch.tweakLibraries(in: binary)
                out.append(Stored(build: build, libraries: libraries, injected: !libraries.isEmpty))
            }
            return out
        }.value
        items = read
        isReading = false
    }

    /// Copies the cached build, removes the libraries from its main binary,
    /// repacks it, and installs that.
    private func strip(_ item: Stored) {
        Haptics.destructive()
        Task {
            let target = item.removable
            guard !target.isEmpty else { return }
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("stripped-\(UUID().uuidString).ipa")
            do {
                try await Task.detached(priority: .userInitiated) {
                    try IPAPatch.strip(item.build, libraries: Set(target), writing: temp)
                }.value
                engine.log("Stripped \(target.count) library(ies) from \(item.build.displayName).")
                engine.installLocalIPA(at: temp)
            } catch {
                engine.log("⚠️ Couldn't strip \(item.build.displayName): \(error.localizedDescription)")
            }
        }
    }
}
