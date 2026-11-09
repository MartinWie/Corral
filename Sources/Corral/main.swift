import AppKit
import CorralKit
import GhosttyKit

// Ghostty finds shell integration, themes and terminfo through its resources dir. The app bundle
// carries the copy matching its libghostty, used even when started from a Ghostty terminal (which
// exports Ghostty.app's); a dev build falls back to an inherited or the installed Ghostty.app's.
let bundled = Bundle.main.resourceURL?.appendingPathComponent("ghostty").path
let inherited = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"]
let installed = "/Applications/Ghostty.app/Contents/Resources/ghostty"
if let resources = [bundled, inherited, installed].compactMap({ $0 })
    .first(where: { FileManager.default.fileExists(atPath: $0 + "/shell-integration") }) {
    setenv("GHOSTTY_RESOURCES_DIR", resources, 1)
}

if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
    fputs("ghostty_init failed\n", stderr)
    exit(1)
}

let app = NSApplication.shared
let bench = ProcessInfo.processInfo.environment["CORRAL_BENCH"] != nil
let delegate = AppDelegate(makeTerminals: {
    let runtime = GhosttyRuntime()
    return runtime.app == nil ? nil : runtime
}, updater: bench ? nil : SparkleUpdater.make())
app.delegate = delegate
// Benchmarks run without a Dock icon and never take focus.
app.setActivationPolicy(bench ? .accessory : .regular)
app.run()
