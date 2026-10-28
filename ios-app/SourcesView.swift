import SwiftUI
import UIKit

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
