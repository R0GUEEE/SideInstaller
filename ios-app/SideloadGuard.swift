import Foundation

/// Looking for, and defeating, the checks an app uses to notice it was
/// sideloaded.
///
/// What this can honestly do is limited to the build itself:
///
/// - **Strings.** Jailbreak and sideload checks are usually a list of paths and
///   schemes — `/Applications/Cydia.app`, `cydia://`, `embedded.mobileprovision`
///   — stored as C strings in the executable. Blanking the first byte of each
///   leaves the file's layout untouched (same length, same offsets) and makes
///   the check compare against an empty string, which no file or URL is.
/// - **Frameworks.** `DeviceCheck` and `AppAttest` mean the app attests its
///   install to a server. Nothing on-device can defeat that; finding them is
///   reported so the limit is visible rather than a silent failure.
/// - **Entitlements.** `get-task-allow` is the entitlement a development-signed
///   build carries and an App Store build doesn't; the patch writes it false.
///
/// It can't help an app whose check is server-side, or one that inspects the
/// signature's team ID. It also can't patch Swift string literals inlined into
/// code, which is why the report names what was found instead of promising
/// invisibility.
enum SideloadGuard {

    /// A path or scheme worth neutralising — long enough that a false positive
    /// in ordinary code is unlikely.
    struct Marker {
        let needle: String
        let label: String
    }

    static let markers: [Marker] = [
        Marker(needle: "/Applications/Cydia.app", label: L("Cydia installed")),
        Marker(needle: "/private/jailbreak.txt", label: L("jailbreak marker file")),
        Marker(needle: "/var/lib/dpkg/status", label: L("dpkg status")),
        Marker(needle: "/var/jb/", label: L("rootless jailbreak root")),
        Marker(needle: "cydia://", label: L("Cydia URL scheme")),
        Marker(needle: "sileo://", label: L("Sileo URL scheme")),
        Marker(needle: "embedded.mobileprovision", label: L("embedded provisioning profile")),
        Marker(needle: "get-task-allow", label: L("get-task-allow entitlement")),
        Marker(needle: "frida", label: L("Frida")),
        Marker(needle: "substrate", label: L("Substrate")),
    ]

    /// Frameworks that mean the app can prove where it was installed from.
    static let attestationFrameworks = ["DeviceCheck", "AppAttest"]

    struct Report {
        var markers: [String] = []
        var frameworks: [String] = []
        /// True when anything was found that a bypass could address.
        var hasPatchable: Bool { !markers.isEmpty }
        /// True when something was found that can't be handled here.
        var hasUnpatchable: Bool { !frameworks.isEmpty }
        var isEmpty: Bool { markers.isEmpty && frameworks.isEmpty }
    }

    /// Reads the build's main executable and reports what it found. Off the
    /// main actor — this is a decompression pass.
    static func scan(_ ipa: URL) -> Report {
        var report = Report()
        guard let archive = IPALibrary.archiveFiles(at: ipa),
              let info = IPAPatch.readInfoPlist(from: ipa) else { return report }

        let executable = (info["CFBundleExecutable"] as? String) ?? ""

        // The libraries it links, for attestation.
        if let binary = executableData(archive: archive, url: ipa, executable: executable) {
            let links = MachOInject.linkedLibraries(in: binary)
            for link in links {
                if let match = attestationFrameworks.first(where: {
                    (link as NSString).lastPathComponent.contains($0)
                }), !report.frameworks.contains(match) {
                    report.frameworks.append(match)
                }
            }
            // Byte search rather than String(decoding:): a 48 MB prefix as a
            // Swift String is another few hundred megabytes of working set for
            // a handful of `contains` checks.
            let bytes = [UInt8](binary)
            for marker in markers where contains(Array(marker.needle.utf8), in: bytes) {
                report.markers.append(marker.label)
            }
        }
        return report
    }

    private static func contains(_ needle: [UInt8], in haystack: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        let last = haystack.count - needle.count
        var index = 0
        while index <= last {
            if haystack[index] == needle[0],
               Array(haystack[index..<(index + needle.count)]) == needle { return true }
            index += 1
        }
        return false
    }

    /// Blanks the first byte of every known marker in the binary, in place.
    /// Returns the same bytes with those C strings made empty, and what it hit.
    static func patch(_ binary: Data) -> (data: Data, hits: [String]) {
        var bytes = [UInt8](binary)
        var hits: [String] = []
        for marker in markers {
            let needle = Array(marker.needle.utf8)
            guard !needle.isEmpty else { continue }
            var hit = false
            var index = 0
            while index + needle.count <= bytes.count {
                if bytes[index] == needle[0],
                   Array(bytes[index..<(index + needle.count)]) == needle {
                    // An empty C string: same length, no layout change, and no
                    // path or scheme left to match.
                    bytes[index] = 0
                    hit = true
                    index += needle.count
                } else {
                    index += 1
                }
            }
            if hit { hits.append(marker.label) }
        }
        return (Data(bytes), hits)
    }

    /// The main executable's bytes, read the same way the injector reads them.
    static func executableData(archive: [IPALibrary.ArchiveFile], url: URL,
                               executable: String) -> Data? {
        guard !executable.isEmpty,
              let entry = archive.first(where: {
                  $0.path.hasSuffix("/" + executable) && $0.path.contains("Payload/")
              }) else { return nil }
        // A bounded read: strings and load commands live well inside the first
        // few tens of megabytes of any real app.
        return IPALibrary.prefix(of: entry, in: url, limit: 24 << 20)
    }
}
