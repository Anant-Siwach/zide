import AppKit

let app = NSApplication.shared
if let i = CommandLine.arguments.firstIndex(of: "--agenttest") {
    let a = CommandLine.arguments
    app.delegate = AppDelegate.shared
    app.setActivationPolicy(.accessory)
    DispatchQueue.main.async { MainActor.assumeIsolated { AgentTest.run(a[i + 1]) } }
    app.run()
}
if let i = CommandLine.arguments.firstIndex(of: "--nbtest") {
    let a = CommandLine.arguments
    app.delegate = AppDelegate.shared
    app.setActivationPolicy(.accessory)
    DispatchQueue.main.async { MainActor.assumeIsolated { NBTest.run(a[i + 1]) } }
    app.run()
}
if let i = CommandLine.arguments.firstIndex(of: "--newfeaturestest") {
    let a = CommandLine.arguments
    app.delegate = AppDelegate.shared
    app.setActivationPolicy(.accessory)
    DispatchQueue.main.async { MainActor.assumeIsolated { NewFeaturesTest.run(a[i + 1], port: a[i + 2], pgPort: a[i + 3]) } }
    app.run()
}
if let i = CommandLine.arguments.firstIndex(of: "--featurestest") {
    let dir = CommandLine.arguments[i + 1]
    app.delegate = AppDelegate.shared
    app.setActivationPolicy(.accessory)
    DispatchQueue.main.async { MainActor.assumeIsolated { FeaturesTest.run(dir) } }
    app.run()
}
if let i = CommandLine.arguments.firstIndex(of: "--extrastest") {
    let dir = CommandLine.arguments[i + 1]
    app.delegate = AppDelegate.shared
    app.setActivationPolicy(.accessory)
    DispatchQueue.main.async { MainActor.assumeIsolated { ExtrasTest.run(dir) } }
    app.run()
}
if let i = CommandLine.arguments.firstIndex(of: "--texttoolstest") {
    let dir = CommandLine.arguments[i + 1]
    app.setActivationPolicy(.prohibited)
    DispatchQueue.main.async { MainActor.assumeIsolated { TextToolsTest.run(dir) } }
    app.run()
}
if let i = CommandLine.arguments.firstIndex(of: "--uishot") {
    _ = UIShot.started
    let args = Array(CommandLine.arguments[(i + 1)...])
    app.delegate = AppDelegate.shared
    app.setActivationPolicy(.accessory)
    DispatchQueue.main.async { MainActor.assumeIsolated { UIShot.run(args) } }
} else if let i = CommandLine.arguments.firstIndex(of: "--editortest2") {
    app.setActivationPolicy(.prohibited)
    let dir = CommandLine.arguments[i + 1]
    DispatchQueue.main.async { MainActor.assumeIsolated { EditorSelfTest2.run(dir) } }
} else if let i = CommandLine.arguments.firstIndex(of: "--editortest") {
    app.setActivationPolicy(.prohibited)
    let dir = CommandLine.arguments[i + 1]
    DispatchQueue.main.async { MainActor.assumeIsolated { EditorSelfTest.run(dir) } }
} else if let i = CommandLine.arguments.firstIndex(of: "--debugtest") {
    app.setActivationPolicy(.prohibited)
    let args = Array(CommandLine.arguments[(i + 1)...])
    DispatchQueue.main.async { MainActor.assumeIsolated { DebugSelfTest.run(args) } }
} else if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
    app.setActivationPolicy(.prohibited)
    let args = Array(CommandLine.arguments[(i + 1)...])
    DispatchQueue.main.async { MainActor.assumeIsolated { SelfTest.run(args) } }
} else {
    app.delegate = AppDelegate.shared
    app.setActivationPolicy(.regular)
}
app.run()
