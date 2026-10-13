import AppKit

if CommandLine.arguments.contains(ClaudeHook.argument) { ClaudeHook.run() }
// `--export-help <folder>` draws Help into PNG files and quits before the app starts.
HelpExport.runIfRequested()

// Top-level code runs on the main thread; AppKit and the delegate are main-actor.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
