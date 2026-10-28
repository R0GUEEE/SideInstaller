import Foundation

func L(_ key: String) -> String { key }
func L(_ key: String, _ arguments: CVarArg...) -> String { key }

// Arguments: JSON files to read (a source document each).
var failures = 0
for path in CommandLine.arguments.dropFirst() {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        print("FAILED to read \(path)"); failures += 1; continue
    }
    let source = AltSource(data: data)
    let total = source.apps.count
    let installable = source.installableApps.count
    let expected = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["apps"] as? [Any] ?? []
    print("\(path): apps=\(total) installable=\(installable) raw=\(expected.count)")
    if total != expected.count {
        print("  FAILED: \(expected.count - total) apps were dropped in decoding")
        failures += 1
    }
    // Every v1 app (no versions) must keep its top-level release.
    for app in source.apps where (app.versions ?? []).isEmpty {
        if app.releases.isEmpty {
            print("  FAILED: \(app.name) has no release")
            failures += 1
        }
    }
}
exit(failures == 0 ? 0 : 1)
