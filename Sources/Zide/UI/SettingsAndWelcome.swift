import AppKit
import SwiftUI

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(tab: Int = 0) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Zide Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }
            EditorSettings().tabItem { Label("Editor", systemImage: "text.cursor") }
            LanguageSettings().tabItem { Label("Languages", systemImage: "chevron.left.forwardslash.chevron.right") }
            ToolsSettings().tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
        }
        .padding()
        .frame(minWidth: 680, minHeight: 480)
    }
}

private struct AppearanceSettings: View {
    @ObservedObject var prefs = Prefs.shared
    private let fonts: [String] = ["SF Mono"] + NSFontManager.shared.availableFontFamilies.filter { name in
        guard let f = NSFont(name: name, size: 12) else { return false }
        return f.isFixedPitch || name.localizedCaseInsensitiveContains("mono") || name.localizedCaseInsensitiveContains("code")
    }.filter { $0 != "SF Mono" }

    var body: some View {
        Form {
            Picker("Theme", selection: $prefs.theme) { ForEach(ThemeChoice.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented)
            Picker("Editor font", selection: $prefs.fontName) { ForEach(fonts, id: \.self) { Text($0).tag($0) } }
            LabeledContent("Font size") {
                Stepper("\(Int(prefs.fontSize)) pt", value: $prefs.fontSize, in: 8...32, step: 1)
            }
            LabeledContent("Line height") {
                Slider(value: $prefs.lineHeight, in: 1.0...2.0, step: 0.05).frame(width: 200)
                Text(String(format: "%.2f", prefs.lineHeight)).monospacedDigit()
            }
            LabeledContent("Terminal font size") {
                Stepper("\(Int(prefs.terminalFontSize)) pt", value: $prefs.terminalFontSize, in: 8...28, step: 1)
            }
            Text("The quick brown fox → fn main() { let x = 42; }")
                .font(Font(prefs.editorFont))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
        .formStyle(.grouped)
    }
}

private struct EditorSettings: View {
    @ObservedObject var prefs = Prefs.shared
    var body: some View {
        Form {
            Section("Indentation") {
                Stepper("Tab width: \(prefs.tabWidth)", value: $prefs.tabWidth, in: 1...8)
                Toggle("Indent with spaces", isOn: $prefs.insertSpaces)
            }
            Section("Editing") {
                Toggle("Soft-wrap long lines", isOn: $prefs.wordWrap)
                Toggle("Insert closing brackets and quotes", isOn: $prefs.autoClosePairs)
                Toggle("Show indent guides", isOn: $prefs.showMinimapGuides)
                Toggle("Sticky scroll (pin the enclosing function/class header)", isOn: $prefs.stickyScroll)
                Toggle("Rainbow brackets", isOn: $prefs.rainbowBrackets)
                Toggle("Follow log files: stay at the end when they grow", isOn: $prefs.followLogs)
                Toggle("Style Markdown while editing (headings, bold, italic, checkboxes)", isOn: $prefs.markdownStyling)
                Toggle("Check spelling in notes and Markdown", isOn: $prefs.spellCheck)
                Toggle("Keep Zide ready in the background after closing the last window (instant reopen)", isOn: $prefs.keepWarm)
                Toggle("⌃⌥N anywhere opens a new quick note", isOn: $prefs.quickNoteHotkey)
                Toggle("Show documentation on mouse hover", isOn: $prefs.hoverDocs)
                Toggle("Show inlay hints (parameter names and types)", isOn: $prefs.inlayHints)
            }
            Section("Saving") {
                Toggle("Save files automatically (like JetBrains)", isOn: $prefs.autosave)
                Toggle("Reformat code on save", isOn: $prefs.formatOnSave)
                Toggle("Strip trailing spaces and add a final newline on save", isOn: $prefs.trimWhitespace)
            }
            Section("Git") {
                Toggle("Show who last changed the current line (blame) in the status bar", isOn: $prefs.showBlame)
            }
        }
        .formStyle(.grouped)
    }
}

private struct LanguageSettings: View {
    @State private var resolved: [String: String] = [:]
    @State private var loading = true
    private let languages = Language.all.filter { !$0.servers.isEmpty }.reduce(into: [Language]()) { acc, l in
        if !acc.contains(where: { LSPManager.key($0) == LSPManager.key(l) }) { acc.append(l) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Zide uses each language's own language server for completion, errors, go to definition, rename and formatting — the same servers VS Code and Zed use. Syntax colouring, search, run and Git work for every language without one.")
                .font(.callout).foregroundStyle(.secondary)
            List {
                Section("Debuggers") {
                    DebuggerRow(name: "Swift / C / C++ / Objective-C / Rust / Zig", tool: "lldb-dap", check: {
                        Shell.run("xcrun", ["--find", "lldb-dap"]).ok
                    }, install: "xcode-select --install")
                    DebuggerRow(name: "Python", tool: "debugpy", check: {
                        Env.which("python3").map { Shell.run($0, ["-c", "import debugpy"]).ok } ?? false
                    }, install: "pip3 install debugpy")
                }
                Section("Language servers") {
                ForEach(languages) { lang in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayName(lang)).font(.system(size: 13, weight: .medium))
                            Text(lang.servers.map(\.command).joined(separator: " / ")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if loading {
                            ProgressView().controlSize(.small)
                        } else if let path = resolved[lang.id] {
                            Label((path as NSString).abbreviatingWithTildeInPath, systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green).lineLimit(1).truncationMode(.middle).frame(maxWidth: 260, alignment: .trailing)
                        } else if let spec = lang.servers.first {
                            Text(spec.install).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            Button("Install") { AppDelegate.shared.runInTerminal(spec.install, title: "Install \(spec.command)") }
                        }
                    }
                    .padding(.vertical, 2)
                }
                }
            }
        }
        .task {
            let langs = languages
            let found = await Task.detached { () -> [String: String] in
                var m: [String: String] = [:]
                for l in langs { if let (_, p) = LSPManager.resolve(l) { m[l.id] = p } }
                return m
            }.value
            resolved = found
            loading = false
        }
    }

    private func displayName(_ l: Language) -> String {
        switch LSPManager.key(l) {
        case "typescript": return "TypeScript / JavaScript"
        case "clangd": return "C / C++ / Objective-C"
        default: return l.name
        }
    }
}

private struct DebuggerRow: View {
    let name: String
    let tool: String
    let check: @Sendable () -> Bool
    let install: String
    @State private var ok: Bool?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13, weight: .medium))
                Text(tool).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let ok {
                if ok { Label("Installed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
                else {
                    Text(install).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Install") { AppDelegate.shared.runInTerminal(install, title: "Install \(tool)") }
                }
            } else { ProgressView().controlSize(.small) }
        }
        .task { let c = check; ok = await Task.detached { c() }.value }
    }
}

private struct ToolsSettings: View {
    @State private var cliStatus = ""
    var body: some View {
        Form {
            Section("Command-line launcher") {
                Text("Open folders from Terminal with `zide .` or `zide path/to/file`.").font(.callout)
                HStack {
                    Button("Install 'zide' Command") { cliStatus = AppDelegate.shared.installCLI() }
                    Text(cliStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Shell") {
                LabeledContent("PATH used for tools") {
                    Text(Env.path.prefix(6).joined(separator: ":") + "…").font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Welcome

@MainActor
enum WelcomeWindow {
    private static var window: NSWindow?
    static var isVisible: Bool { window?.isVisible ?? false }

    static func show() {
        AppDelegate.shared.wake()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 470), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: WelcomeView())
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close() { window?.orderOut(nil) }
}

private struct WelcomeView: View {
    @State private var recents = Prefs.shared.recentProjects
    @State private var filter = ""

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 14) {
                Spacer()
                if let icon = NSApp.applicationIconImage { Image(nsImage: icon).resizable().frame(width: 96, height: 96) }
                Text("Zide").font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")").foregroundStyle(.secondary)
                Spacer()
                VStack(spacing: 8) {
                    WelcomeButton(title: "Open…", icon: "folder") { AppDelegate.shared.openPanel() }
                    WelcomeButton(title: "New Project…", icon: "plus.rectangle.on.folder") { AppDelegate.shared.newProject() }
                    WelcomeButton(title: "Clone Repository…", icon: "arrow.down.doc") { AppDelegate.shared.cloneRepository() }
                }
                .padding(.bottom, 30)
            }
            .frame(width: 280)
            .background(.ultraThinMaterial)
            VStack(alignment: .leading, spacing: 8) {
                TextField("Search projects", text: $filter).textFieldStyle(.roundedBorder).padding(.top, 36)
                if recents.isEmpty {
                    Text("Recent projects appear here.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(recents.filter { filter.isEmpty || $0.path.localizedCaseInsensitiveContains(filter) }, id: \.self) { url in
                                RecentRow(url: url) { AppDelegate.shared.openProject(url) } remove: {
                                    Prefs.shared.removeRecent(url); recents = Prefs.shared.recentProjects
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 20)
        }
        .frame(width: 760, height: 470)
    }
}

private struct WelcomeButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).frame(width: 200, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
                .background(hover ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct RecentRow: View {
    let url: URL
    let open: () -> Void
    let remove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Text(String(url.lastPathComponent.prefix(2)).uppercased())
                .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).font(.system(size: 13, weight: .medium))
                Text((url.path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if hover { Button(action: remove) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Remove from list") }
        }
        .padding(8)
        .background(hover ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hover = $0 }
    }

    private var color: Color {
        let colors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .red]
        return colors[url.lastPathComponent.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % colors.count]
    }
}
