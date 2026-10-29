import SwiftUI

/// **Downloads**: the `.ipa` files already on this iPhone — the preset builds a
/// previous run fetched, and anything imported from Files — with the choice the
/// marketplace row no longer makes for you: configure it in the install menu, or
/// install it straight away.
struct DownloadsLibraryView: View {
    @EnvironmentObject private var engine: Engine
    @EnvironmentObject private var loc: Localizer
    @Environment(\.dismiss) private var dismiss

    @StateObject private var manager = DownloadsManager()
    @State private var pendingDelete: DownloadedIPA?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if manager.downloads.isEmpty {
                        emptyState
                    } else {
                        ForEach(manager.downloads) { item in
                            row(item)
                        }
                        Text(L("Every .ipa SideInstaller has downloaded or imported, kept in Documents. Handing one to the install menu is what lets it be configured before signing."))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                }
                .padding(20)
                .pageColumn()
            }
            .background(AppBackground())
            .navigationTitle(L("Downloads"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                }
            }
            .onAppear { manager.refresh() }
            .confirmationDialog(L("Delete this download?"),
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                presenting: pendingDelete) { item in
                Button(L("Delete %@", item.displayName), role: .destructive) {
                    manager.delete(item)
                    pendingDelete = nil
                    Haptics.destructive()
                }
                Button(L("Cancel"), role: .cancel) { pendingDelete = nil }
            } message: { item in
                Text(L("%@ (%@) is removed from this iPhone. An app already installed from it stays.", item.displayName, item.sizeText))
            }
        }
    }

    // MARK: Rows

    private func row(_ item: DownloadedIPA) -> some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    icon(item)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(detail(item))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Menu {
                        ShareLink(item: item.url) {
                            Label(L("Share the file"), systemImage: "square.and.arrow.up")
                        }
                        Divider()
                        Button(role: .destructive) {
                            pendingDelete = item
                        } label: {
                            Label(L("Delete"), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 8) {
                    Button {
                        configure(item)
                    } label: {
                        Label(L("Configure"), systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(engine.isRunning || engine.isImportingIPA)

                    Button {
                        install(item)
                    } label: {
                        Label(L("Install"), systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(engine.isRunning || engine.isImportingIPA)
                }
            }
        }
    }

    private func icon(_ item: DownloadedIPA) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.brand)
            Image(systemName: symbol(item))
                .font(.title3)
                .foregroundStyle(.white)
        }
        .frame(width: 44, height: 44)
    }

    private func symbol(_ item: DownloadedIPA) -> String {
        switch item.source {
        case .sideStore:     return "shippingbox.fill"
        case .liveContainer: return "square.stack.3d.up.fill"
        case .madeira:       return "bolt.horizontal.circle.fill"
        case .custom:        return "doc.fill"
        }
    }

    private func detail(_ item: DownloadedIPA) -> String {
        var parts = [item.sizeText]
        if let date = item.modified {
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        if item.source != .custom { parts.append(item.fileName) }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    /// Imports the file as the custom build and lands on the Install tab, where
    /// the signing configuration is waiting.
    private func configure(_ item: DownloadedIPA) {
        Haptics.tap()
        Task { await engine.importCustomIPA(from: item.url) }
        dismiss()
    }

    /// Imports and runs in one go, for when nothing needs changing.
    private func install(_ item: DownloadedIPA) {
        Haptics.tap()
        engine.installLocalIPA(at: item.url)
        dismiss()
    }

    private var emptyState: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Nothing downloaded yet"))
                    .font(.headline)
                Text(L("A preset build is kept here after it downloads, and an .ipa opened from Files or a link is kept too. Both can be handed to the install menu from this page."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
