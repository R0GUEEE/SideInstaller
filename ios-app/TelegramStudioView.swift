import SwiftUI
import UIKit

/// The Telegram screen: which channels to watch, a scan of what they carry, and
/// the source file built from it.
///
/// It states plainly what it can and can't do. Reading a channel needs either a
/// signed-in Telegram client or the channel's public preview; this uses the
/// preview, so it works without an account, can't download files, and can't see
/// channels that turned previews off.
struct TelegramStudioView: View {
    @EnvironmentObject private var loc: Localizer
    @ObservedObject private var studio = TelegramStudio.shared
    @Environment(\.dismiss) private var dismiss

    @State private var newChannel = ""
    @State private var addError: String?
    @State private var showAccountInfo = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 18) {
                    accountCard
                    addCard
                    channelCard
                    scanCard
                    sourceCard
                }
                .padding(20)
                .pageColumn()
            }
            .background(AppBackground())
            .navigationTitle(L("Telegram"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                }
            }
            .sheet(isPresented: $showAccountInfo) { accountExplanation }
        }
    }

    // MARK: Account

    /// The truth about signing in, rather than a button that can't work.
    private var accountCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(L("Account"), systemImage: "person.crop.circle.badge.questionmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(L("Not signed in"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(L("SideInstaller reads channels through Telegram's public previews — no account, no phone number, no session on this iPhone. A channel that has previews switched off can't be read this way, and files always download inside Telegram."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("What signing in would take")) { showAccountInfo = true }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
            }
        }
    }

    private var accountExplanation: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L("Reading a channel as your Telegram account"))
                        .font(.headline)
                    Text(L("Telegram's API isn't open. A signed-in client is an MTProto session, and building one means:"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach([
                            L("an api_id and api_hash from my.telegram.org, for this app"),
                            L("a phone-number login: Telegram sends a code to your other devices or by SMS"),
                            L("the 2FA password, for accounts that have one"),
                            L("a session key kept on this device — a credential as sensitive as your Apple ID"),
                            L("a file download path, because a session is the only thing that can fetch a file"),
                        ], id: \.self) { line in
                            Label(line, systemImage: "circle.fill")
                                .font(.caption)
                                .labelStyle(BulletLabelStyle())
                        }
                    }
                    Text(L("That is a real piece of work, and it puts a Telegram session in the app. The channel selection, deep scan and generated source in this screen don't need any of it — they work now. If you want the signed-in version, it can be built next, as its own step."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .pageColumn()
            }
            .background(AppBackground())
            .navigationTitle(L("Signing in"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: Add

    private var addCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(L("Add a channel"), systemImage: "plus.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("t.me/channel", text: $newChannel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.subheadline)
                    Button {
                        addError = studio.add(newChannel)
                        if addError == nil { newChannel = "" }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.accent2)
                    }
                    .buttonStyle(.plain)
                    .disabled(newChannel.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .fieldBackground()
                if let addError {
                    Text(addError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(L("Public channels only. A channel's preview is what gets read — around twenty posts a page, and pages can be walked back."))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Channels

    private var channelCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(L("%ld channels", studio.channels.count), systemImage: "paperplane")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                if studio.channels.isEmpty {
                    Text(L("No channels yet."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(studio.channels) { channel in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Toggle(isOn: Binding(get: { channel.enabled },
                                                 set: { studio.setEnabled($0, for: channel.id) })) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(channel.title.isEmpty ? "@\(channel.handle)" : channel.title)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Text("@\(channel.handle)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            Button(role: .destructive) {
                                studio.remove(channel.id)
                            } label: {
                                Image(systemName: "trash").font(.footnote)
                            }
                            .buttonStyle(.borderless)
                        }
                        Stepper(value: Binding(get: { channel.pages },
                                               set: { studio.setPages($0, for: channel.id) }),
                                in: 1...20) {
                            Text(L("Scan %ld page(s) · ~%ld posts", channel.pages, channel.pages * 20))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    if channel.id != studio.channels.last?.id { Divider().opacity(0.15) }
                }
            }
        }
    }

    // MARK: Scan

    private var scanCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button {
                        Task { await studio.scan() }
                    } label: {
                        Label(studio.isScanning ? L("Scanning…") : L("Scan channels"),
                              systemImage: "antenna.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(studio.isScanning || studio.channels.allSatisfy { !$0.enabled })
                }
                if studio.isScanning { ProgressView().controlSize(.small) }
                if let note = studio.scanNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(studio.results) { result in
                    HStack(alignment: .top, spacing: 8) {
                        Text("@\(result.channel)")
                            .font(.caption.monospaced())
                        Spacer(minLength: 4)
                        if let error = result.error {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.trailing)
                                .lineLimit(2)
                        } else {
                            Text(L("%ld apps", result.entries.count))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: Source

    private var sourceCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(L("Live source"), systemImage: "link")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(L("Turns the scan into an AltStore-format source, written to this app's Documents as Telegram/telegram-source.json. Add it here with the link below, or copy the JSON and host it anywhere for SideStore or AltStore. Regenerate it after a scan to keep it current."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    if let generated = studio.generateSource() {
                        UIPasteboard.general.string = generated.url.absoluteString
                    }
                } label: {
                    Label(L("Generate the source file"), systemImage: "square.and.arrow.down.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(studio.allEntries.isEmpty)

                if let generated = studio.generated {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("%ld apps · %ld releases · %@", generated.apps, generated.releases,
                               generated.generatedAt.formatted(date: .omitted, time: .shortened)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(generated.url.path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    HStack(spacing: 8) {
                        Button {
                            UIPasteboard.general.string = generated.url.absoluteString
                        } label: {
                            Label(L("Copy URL"), systemImage: "doc.on.doc")
                                .font(.footnote.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        Button {
                            share(generated.url)
                        } label: {
                            Label(L("Share JSON"), systemImage: "square.and.arrow.up")
                                .font(.footnote.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func share(_ url: URL) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        var controller = root
        while let presented = controller.presentedViewController { controller = presented }
        controller.present(UIActivityViewController(activityItems: [url], applicationActivities: nil),
                           animated: true)
    }
}

/// A small dot instead of an SF Symbol, for a plain bulleted list.
private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon
                .font(.system(size: 4))
                .foregroundStyle(.tertiary)
            configuration.title
        }
    }
}
