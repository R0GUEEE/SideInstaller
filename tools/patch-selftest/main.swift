import Foundation

// Stand-in for the app's localisation lookup: the harness has no language
// tables, and the messages only matter on device.
func L(_ key: String) -> String { key }
func L(_ key: String, _ arguments: CVarArg...) -> String { key }

// Arguments: <ipa> <tweak.dylib>
guard CommandLine.arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: patch-selftest <ipa> <tweak.dylib>\n".utf8))
    exit(64)
}
let ipa = URL(fileURLWithPath: CommandLine.arguments[1])
let tweak = CommandLine.arguments[2]

var config = AppConfig()
config.bundleIdentifier = "com.example.renamed"
config.displayName = "Renamed App"
config.version = "9.9"
config.build = "42"
config.stripWatchApp = true
config.tweaks = [AppConfig.Tweak(name: "TestTweak.dylib",
                                 path: tweak,
                                 loadPath: "@executable_path/Frameworks/TestTweak.dylib")]

do {
    let outcome = try IPAPatch.apply(config, to: ipa)
    print("APPLIED")
    for line in outcome.applied { print("  + \(line)") }
    for line in outcome.warnings { print("  ! \(line)") }
} catch {
    print("FAILED: \(error.localizedDescription)")
    exit(1)
}

// A second pass must be a no-op: same identity, same tweak, nothing rewritten.
do {
    let second = try IPAPatch.apply(config, to: ipa)
    print("SECOND PASS")
    for line in second.applied { print("  + \(line)") }
    for line in second.warnings { print("  ! \(line)") }
    if second.applied.contains(where: { $0.contains("Injected") }) {
        print("FAILED: the tweak was injected twice")
        exit(1)
    }
} catch {
    print("FAILED on the second pass: \(error.localizedDescription)")
    exit(1)
}
