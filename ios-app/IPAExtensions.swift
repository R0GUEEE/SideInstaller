import Foundation

/// The extension bundles inside an IPA, read from its archive.
///
/// Reading them up front is what lets the install menu say, before a run, that
/// an app ships plugins and whether each one's identifier sits under the app's —
/// the condition iOS enforces, and the one the signer refuses on.
enum IPAExtensions {

    static func read(_ ipa: URL) -> [Engine.BuildExtension] {
        guard let archive = IPALibrary.archiveFiles(at: ipa) else { return [] }
        return read(archive: archive, ipa: ipa)
    }

    static func read(archive: [IPALibrary.ArchiveFile], ipa: URL) -> [Engine.BuildExtension] {
        // The app's own identifier, so each extension can be compared with it.
        guard let appInfo = IPAPatch.readInfoPlist(from: ipa),
              let appID = appInfo["CFBundleIdentifier"] as? String,
              let app = archive.first(where: {
                  $0.path.hasSuffix("/Info.plist") && $0.path.contains("Payload/")
                      && $0.path.split(separator: "/").count == 3
              }) else { return [] }
        let prefix = String(app.path.dropLast("Info.plist".count))

        var out: [Engine.BuildExtension] = []
        for file in archive where file.path.hasPrefix(prefix) && file.path.hasSuffix("/Info.plist") {
            let parts = file.path.split(separator: "/").map(String.init)
            guard let leaf = parts.dropLast().last, leaf.hasSuffix(".appex") else { continue }
            guard let data = IPALibrary.contents(of: file, in: ipa),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any],
                  let bundleID = plist["CFBundleIdentifier"] as? String else { continue }
            let path = String(file.path.dropLast("Info.plist".count))
            out.append(Engine.BuildExtension(
                path: path.replacingOccurrences(of: prefix, with: ""),
                bundleID: bundleID,
                isChild: bundleID.hasPrefix(appID + ".")))
        }
        return out.sorted { $0.path < $1.path }
    }
}
