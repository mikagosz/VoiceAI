import AppKit

if CommandLine.arguments.contains(ClaudeHook.argument) { ClaudeHook.run() }

// Top-level code runs on the main thread; AppKit and the delegate are main-actor.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
