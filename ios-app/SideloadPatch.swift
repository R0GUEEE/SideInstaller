import Foundation

/// The byte-level half of the sideload-detection patch: which strings to look
/// for, and how to empty them without moving anything.
///
/// Kept apart from `SideloadGuard` (which reads an archive) so the patch itself
/// compiles into the patch selftest, which has no IPA code.
enum SideloadPatch {

    struct Marker {
        let needle: String
        let label: String
    }

    static let markers: [Marker] = [
        Marker(needle: "/Applications/Cydia.app", label: "Cydia installed"),
        Marker(needle: "/private/jailbreak.txt", label: "jailbreak marker file"),
        Marker(needle: "/var/lib/dpkg/status", label: "dpkg status"),
        Marker(needle: "/var/jb/", label: "rootless jailbreak root"),
        Marker(needle: "cydia://", label: "Cydia URL scheme"),
        Marker(needle: "sileo://", label: "Sileo URL scheme"),
        Marker(needle: "embedded.mobileprovision", label: "embedded provisioning profile"),
        Marker(needle: "get-task-allow", label: "get-task-allow entitlement"),
        Marker(needle: "frida", label: "Frida"),
        Marker(needle: "substrate", label: "Substrate"),
    ]

    /// True when `needle` appears in `haystack`.
    static func contains(_ needle: [UInt8], in haystack: [UInt8]) -> Bool {
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

    /// Blanks the first byte of every marker found, in place: the same length,
    /// the same offsets, and no path or scheme left to match.
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
}
