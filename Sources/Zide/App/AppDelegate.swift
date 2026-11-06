import AppKit
import SwiftUI

/// One window per project.
@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate {
    let workspace: Workspace

    init(root: URL, quickFile: URL? = nil) {
        workspace = Workspace(root: root, quickFile: quickFile)
        let size = quickFile == nil ? NSSize(width: 1280, height: 820) : NSSize(width: 920, height: 700)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = (quickFile ?? root).lastPathComponent
        w.representedURL = quickFile ?? root
        w.minSize = NSSize(width: 760, height: 480)
        w.isReleasedWhenClosed = false
        w.tabbingMode = .preferred
        // Single files share one remembered size; projects remember their own.
        let frameName = quickFile == nil ? "Zide:" + root.path : "Zide:quick"
        if !w.setFrameUsingName(frameName) { w.center() }
        // Autosave names must be unique per window, so single-file windows save their frame on close instead.
        if quickFile == nil { w.setFrameAutosaveName(frameName) }
        super.init(window: w)
        workspace.window = w
        w.contentView = NSHostingView(rootView: WorkspaceView(ws: workspace))
        w.delegate = self
        registerActions()
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        if workspace.isQuick { window?.saveFrame(usingName: "Zide:quick") }
        workspace.close()
        AppDelegate.shared.windowClosed(self)
    }

    func windowDidResignKey(_ notification: Notification) {
        if Prefs.shared.autosave { workspace.saveAll() } // JetBrains saves on frame deactivation
    }

    private var ws: Workspace { workspace }
    private var editor: EditorController? { ws.active?.editor }

    // MARK: Actions (reached through the responder chain from the menus)

    @objc func searchEverywhere(_ sender: Any?) { ws.palette.open(.all) }
    @objc func goToFile(_ sender: Any?) { ws.palette.open(.files) }
    @objc func goToSymbol(_ sender: Any?) { ws.palette.open(.symbols) }
    @objc func findAction(_ sender: Any?) { ws.palette.open(.actions) }
    @objc func recentFiles(_ sender: Any?) { ws.palette.showRecentFiles() }
    @objc func findInFiles(_ sender: Any?) {
        if let tv = editor?.textView, tv.selectedRange().length > 0, tv.selectedRange().length < 200 {
            ws.search.query = (tv.string as NSString).substring(with: tv.selectedRange())
        }
        ws.bottomTab = .find; ws.bottomVisible = true
        if !ws.search.query.isEmpty { ws.search.run() }
    }
    @objc func replaceInFiles(_ sender: Any?) { ws.search.showReplace = true; findInFiles(sender) }
    @objc func saveDocument(_ sender: Any?) { if let d = ws.active { ws.save(d) } }
    @objc func saveAllDocuments(_ sender: Any?) { ws.saveAll() }
    @objc func closeTab(_ sender: Any?) {
        if let d = ws.active { ws.closeDocument(d) } else { window?.performClose(nil) }
    }
    @objc func newFile(_ sender: Any?) { ws.newFile(in: ws.selectedFile.map { u in
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
        return isDir.boolValue ? u : u.deletingLastPathComponent()
    } ?? ws.root) }
    @objc func toggleProject(_ sender: Any?) { toggleSidebar(.project) }
    @objc func toggleCommit(_ sender: Any?) { toggleSidebar(.commit) }
    @objc func toggleStructure(_ sender: Any?) { toggleSidebar(.structure); ws.scheduleSymbols() }
    @objc func toggleTerminal(_ sender: Any?) { toggleBottom(.terminal); ws.terminals.ensureOne() }
    @objc func toggleRunPanel(_ sender: Any?) { toggleBottom(.run) }
    @objc func toggleProblems(_ sender: Any?) { toggleBottom(.problems) }
    @objc func toggleGitLog(_ sender: Any?) { toggleBottom(.git); ws.git.loadLog() }
    @objc func reopenClosedTab(_ sender: Any?) { ws.reopenClosed() }
    @objc func compareWithClipboard(_ sender: Any?) {
        guard let d = ws.active, let text = NSPasteboard.general.string(forType: .string) else { ws.flash("The clipboard has no text"); return }
        Compare.show(ws, left: d.url, rightText: text, right: nil, title: "\(d.name) ↔ Clipboard")
    }
    @objc func compareWithFile(_ sender: Any?) {
        guard let d = ws.active else { return }
        let p = NSOpenPanel()
        p.message = "Compare \(d.name) with…"
        p.directoryURL = d.url.deletingLastPathComponent()
        guard p.runModal() == .OK, let u = p.url else { return }
        Compare.show(ws, left: d.url, rightText: nil, right: u, title: "\(d.name) ↔ \(u.lastPathComponent)")
    }
    @objc func showFileChanges(_ sender: Any?) {
        guard let d = ws.active else { return }
        let rel = ws.relative(d.url)
        guard ws.git.isRepo, let change = ws.git.changes.first(where: { $0.path == rel }) else {
            ws.flash(ws.git.isRepo ? "No changes in \(d.name) since the last commit" : "This file isn't in a git repository"); return
        }
        ws.git.showDiff(change)
        DiffWindow.show(git: ws.git)
    }
    @objc func toggleZen(_ sender: Any?) { withAnimation(.easeOut(duration: 0.2)) { ws.zen.toggle() } }
    @objc func hideAllPanels(_ sender: Any?) {
        let any = ws.sidebarVisible || ws.bottomVisible
        ws.sidebarVisible = !any; ws.bottomVisible = false
    }
    @objc func runSelected(_ sender: Any?) { ws.runner.run() }
    @objc func runCurrentFile(_ sender: Any?) { ws.runner.run(.currentFile) }
    @objc func stopRun(_ sender: Any?) { ws.runner.stop() }
    @objc func editRunConfigs(_ sender: Any?) { RunConfigEditor.present(ws: ws) }
    @objc func goBack(_ sender: Any?) { ws.goBack() }
    @objc func goForward(_ sender: Any?) { ws.goForward() }
    @objc func gitCommit(_ sender: Any?) { toggleSidebar(.commit, forceShow: true) }
    @objc func gitPush(_ sender: Any?) { ws.git.push() }
    @objc func gitPull(_ sender: Any?) { ws.git.pull() }
    @objc func newTerminal(_ sender: Any?) { ws.terminals.newTerminal() }
    @objc func revealInFinder(_ sender: Any?) { NSWorkspace.shared.activateFileViewerSelecting([ws.active?.url ?? ws.root]) }
    @objc func selectInProject(_ sender: Any?) { if let u = ws.active?.url { ws.reveal(u) } }
    @objc func restartServer(_ sender: Any?) { if let d = ws.active { ws.lsp.restart(d.language); ws.flash("Restarted \(d.language.name) language server") } }
    @objc func splitRight(_ sender: Any?) { ws.splitRight() }
    @objc func unsplit(_ sender: Any?) { ws.unsplit() }
    @objc func moveToOtherSplit(_ sender: Any?) { ws.moveToOtherSplit() }
    @objc func focusOtherSplit(_ sender: Any?) { ws.focusOtherSplit() }
    @objc func startDebug(_ sender: Any?) { ws.debug.start() }
    @objc func debugResume(_ sender: Any?) { ws.debug.resume() }
    @objc func debugStepOver(_ sender: Any?) { ws.debug.stepOver() }
    @objc func debugStepInto(_ sender: Any?) { ws.debug.stepInto() }
    @objc func debugStepOut(_ sender: Any?) { ws.debug.stepOut() }
    @objc func toggleDebugPanel(_ sender: Any?) { toggleBottom(.debug) }
    @objc func toggleTodo(_ sender: Any?) { toggleBottom(.todo); ws.scanTodos() }
    @objc func showBookmarks(_ sender: Any?) { ws.bookmarks.showList() }
    @objc func toggleMarkdownPreview(_ sender: Any?) { ws.markdownPreview.toggle() }
    @objc func toggleAssistant(_ sender: Any?) { ws.assistantVisible.toggle() }
    @objc func toggleLivePreview(_ sender: Any?) { ws.livePreview.toggle() }
    @objc func toggleNotebookJSON(_ sender: Any?) { ws.notebookAsText.toggle() }
    @objc func remotePull(_ sender: Any?) { if let r = ws.remote { r.pull(); ws.flash("Pulling from \(r.spec.host)…") } else { ws.flash("This isn't a remote folder") } }
    @objc func remotePushAll(_ sender: Any?) { if let r = ws.remote { r.pushAll() } else { ws.flash("This isn't a remote folder") } }
    @objc func sendHTTPRequest(_ sender: Any?) { if let d = ws.active { NotificationCenter.default.post(name: .sendHTTPRequestAtCaret, object: d) } }
    @objc func exportPDF(_ sender: Any?) { if let d = ws.active { ws.exportPDF(d) } }
    @objc func aiCommitMessage(_ sender: Any?) { toggleSidebar(.commit, forceShow: true); ws.assistant.commitMessage() }
    @objc func showLocalHistory(_ sender: Any?) { if let d = ws.active { LocalHistoryWindow.show(d) } else { ws.flash("Open a file to see its local history") } }
    @objc func newScratchFile(_ sender: Any?) {
        ws.palette.show(title: "New Scratch File", items: Scratches.kinds.map { kind in
            PaletteItem(title: kind.0, subtitle: ".\(kind.1)", icon: FileIcon.symbol(URL(fileURLWithPath: "x.\(kind.1)")),
                        iconColor: FileIcon.color(URL(fileURLWithPath: "x.\(kind.1)"))) { [weak self] in self?.ws.open(Scratches.create(ext: kind.1)) }
        })
    }
    @objc func stopAll(_ sender: Any?) { ws.runner.stop(); ws.debug.stop() }
    @objc func zoomIn(_ sender: Any?) { Prefs.shared.fontSize = min(40, Prefs.shared.fontSize + 1) }
    @objc func zoomOut(_ sender: Any?) { Prefs.shared.fontSize = max(8, Prefs.shared.fontSize - 1) }
    @objc func zoomReset(_ sender: Any?) { Prefs.shared.fontSize = 13 }

    private func toggleSidebar(_ tab: SidebarTab, forceShow: Bool = false) {
        if ws.sidebarVisible && ws.sidebarTab == tab && !forceShow { ws.sidebarVisible = false } else { ws.sidebarTab = tab; ws.sidebarVisible = true }
    }

    private func toggleBottom(_ tab: BottomTab) {
        if ws.bottomVisible && ws.bottomTab == tab { ws.bottomVisible = false } else { ws.bottomTab = tab; ws.bottomVisible = true }
    }

    override func responds(to aSelector: Selector!) -> Bool { super.responds(to: aSelector) }

    /// Fills Find Action with everything in the main menu (titles + shortcuts), like JetBrains.
    private func registerActions() {
        var list: [PaletteAction] = []
        func walk(_ menu: NSMenu, path: String) {
            for item in menu.items {
                if let sub = item.submenu { if item.title != "Open Recent" && item.title != "Services" { walk(sub, path: item.title) }; continue }
                guard let action = item.action, !item.title.isEmpty, !item.isSeparatorItem else { continue }
                let tag = item.tag
                list.append(PaletteAction(title: item.title, shortcut: Self.shortcut(item), icon: "command") { [weak self] in
                    guard let self else { return }
                    self.window?.makeKeyAndOrderFront(nil)
                    let fake = NSMenuItem(); fake.tag = tag
                    NSApp.sendAction(action, to: nil, from: fake)
                })
                _ = path
            }
        }
        if let main = NSApp.mainMenu { walk(main, path: "") }
        list.append(PaletteAction(title: "Settings", shortcut: "⌘,", icon: "gearshape") { SettingsWindow.show() })
        list.append(PaletteAction(title: "Install 'zide' command-line launcher", shortcut: "", icon: "terminal") { [weak self] in
            self?.ws.flash(AppDelegate.shared.installCLI())
        })
        ws.palette.actions = list
    }

    static func shortcut(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let m = item.keyEquivalentModifierMask
        var s = ""
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        let key: String
        switch item.keyEquivalent {
        case "\r": key = "↩"
        case "\u{8}", "\u{7f}": key = "⌫"
        case String(UnicodeScalar(NSUpArrowFunctionKey)!): key = "↑"
        case String(UnicodeScalar(NSDownArrowFunctionKey)!): key = "↓"
        case String(UnicodeScalar(NSF1FunctionKey)!): key = "F1"
        case String(UnicodeScalar(NSF2FunctionKey)!): key = "F2"
        case String(UnicodeScalar(NSF3FunctionKey)!): key = "F3"
        case String(UnicodeScalar(NSF6FunctionKey)!): key = "F6"
        case String(UnicodeScalar(NSF8FunctionKey)!): key = "F8"
        case String(UnicodeScalar(NSF7FunctionKey)!): key = "F7"
        case String(UnicodeScalar(NSF12FunctionKey)!): key = "F12"
        case " ": key = "Space"
        default: key = item.keyEquivalent.uppercased()
        }
        return s + key
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()
    private(set) var controllers: [WorkspaceWindowController] = []
    private var lastShift: Date?
    private var shiftClean = false
    private var launchedWithFiles = false
    /// Test runs open windows without taking keyboard focus from whatever the user is typing in.
    static var quiet = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        Env.warmUp()
        NSApp.mainMenu = MainMenu.build()
        Theme.update()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installDoubleShift()
        QuickNote.register()
        if !launchedWithFiles {
            let last = UserDefaults.standard.stringArray(forKey: "openProjects") ?? []
            let urls = last.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            if urls.isEmpty { WelcomeWindow.show() } else { urls.forEach { openProject($0) } }
        }
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        launchedWithFiles = true
        wake()
        for url in urls { openPath(url) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        wake()
        if !flag { if controllers.isEmpty { WelcomeWindow.show() } else { controllers.last?.showWindow(nil) } }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        UserDefaults.standard.set(controllers.filter { !$0.workspace.isQuick }.map(\.workspace.root.path), forKey: "openProjects")
        for c in controllers { c.workspace.close() }
        return .terminateNow
    }

    /// Back to a normal Dock app when something opens.
    func wake() { if NSApp.activationPolicy() != .regular && !Self.quiet { NSApp.setActivationPolicy(.regular) } }
    @objc func newQuickNote(_ sender: Any?) { QuickNote.open() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Projects

    /// Opens a folder as a project, or a file inside the project that contains it.
    func openPath(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if isDir.boolValue { openProject(url); return }
        let file = url.standardizedFileURL
        if let c = controllers.first(where: { !$0.workspace.isQuick && file.path.hasPrefix($0.workspace.root.path + "/") }) {
            c.showWindow(nil)
            c.workspace.open(file)
            return
        }
        // Inside a repository: open it as a project. Otherwise a light single-file window, like TextEdit.
        // (Looked up on disk — running git here would wait for the login shell's PATH.)
        if let repo = Self.repositoryRoot(containing: file.deletingLastPathComponent()) {
            openProject(repo).workspace.open(file)
            return
        }
        if let c = controllers.first(where: { $0.workspace.quickFile == file }) { c.showWindow(nil); return }
        wake()
        let c = WorkspaceWindowController(root: file.deletingLastPathComponent(), quickFile: file)
        controllers.append(c)
        c.showWindow(nil)
        WelcomeWindow.close()
        if !Self.quiet { NSApp.activate(ignoringOtherApps: true) }
    }

    static func repositoryRoot(containing dir: URL) -> URL? {
        var d = dir.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        while d.path != "/" && d.path != home {
            if FileManager.default.fileExists(atPath: d.appendingPathComponent(".git").path) { return d }
            d = d.deletingLastPathComponent()
        }
        return nil
    }

    @discardableResult
    func openProject(_ url: URL) -> WorkspaceWindowController {
        wake()
        let root = url.standardizedFileURL
        if let c = controllers.first(where: { $0.workspace.root == root && !$0.workspace.isQuick }) {
            c.showWindow(nil)
            return c
        }
        let c = WorkspaceWindowController(root: root)
        controllers.append(c)
        c.showWindow(nil)
        Prefs.shared.addRecent(root)
        WelcomeWindow.close()
        if !Self.quiet { NSApp.activate(ignoringOtherApps: true) }
        return c
    }

    func windowClosed(_ c: WorkspaceWindowController) {
        controllers.removeAll { $0 === c }
        UserDefaults.standard.set(controllers.filter { !$0.workspace.isQuick }.map(\.workspace.root.path), forKey: "openProjects")
        guard controllers.isEmpty else { return }
        // Stay running without a Dock icon, so the next file opens instantly (like a background helper).
        if Prefs.shared.keepWarm && !Self.quiet {
            DispatchQueue.main.async { if self.controllers.isEmpty && !WelcomeWindow.isVisible { NSApp.setActivationPolicy(.accessory) } }
        } else {
            DispatchQueue.main.async { WelcomeWindow.show() }
        }
    }

    @objc func openPanel() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowsMultipleSelection = true
        p.message = "Choose a project folder or file"
        if p.runModal() == .OK { p.urls.forEach(openPath) }
    }

    @objc func newProject() {
        let p = NSSavePanel()
        p.title = "New Project"
        p.prompt = "Create"
        p.nameFieldStringValue = "untitled"
        p.canCreateDirectories = true
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            openProject(url)
        } catch { NSAlert(error: error).runModal() }
    }

    @objc func cloneRepository() {
        let a = NSAlert()
        a.messageText = "Clone Repository"
        a.informativeText = "Repository URL (https or ssh)"
        let field = NSTextField(string: "")
        field.placeholderString = "https://github.com/user/repo.git"
        field.frame = NSRect(x: 0, y: 0, width: 380, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: "Choose Folder…"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let repo = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !repo.isEmpty else { return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Clone Here"
        guard p.runModal() == .OK, let parent = p.url else { return }
        let name = (repo as NSString).lastPathComponent.replacingOccurrences(of: ".git", with: "")
        let dest = parent.appendingPathComponent(name)
        let progress = NSAlert()
        progress.messageText = "Cloning \(name)…"
        progress.addButton(withTitle: "Hide")
        Task.detached {
            let r = Shell.run("git", ["clone", repo, dest.path])
            await MainActor.run {
                NSApp.abortModal()
                if r.ok { self.openProject(dest) } else {
                    let e = NSAlert(); e.messageText = "Clone failed"; e.informativeText = String(r.err.suffix(1500)); e.runModal()
                }
            }
        }
        progress.runModal()
    }

    /// Runs a command in a terminal tab of the frontmost project (or Terminal.app if none is open).
    func runInTerminal(_ command: String, title: String) {
        if let c = controllers.first(where: { $0.window?.isKeyWindow == true }) ?? controllers.last {
            c.workspace.terminals.newTerminal(command: command, title: title)
            c.showWindow(nil)
        } else {
            let script = "tell application \"Terminal\" to do script \"\(command.replacingOccurrences(of: "\"", with: "\\\""))\""
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        }
    }

    /// Writes a `zide` launcher script into a writable directory on PATH.
    func installCLI() -> String {
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
        let script = "#!/bin/sh\n# Opens files or folders in Zide.\nif [ $# -eq 0 ]; then open -a \"\(Bundle.main.bundlePath)\"; else open -a \"\(Bundle.main.bundlePath)\" \"$@\"; fi\n"
        for dir in candidates where FileManager.default.isWritableFile(atPath: dir) || (dir.hasPrefix(NSHomeDirectory()) && (try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)) != nil) {
            let path = dir + "/zide"
            do {
                try script.write(toFile: path, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
                return "Installed \(path)"
            } catch { continue }
        }
        return "Couldn't find a writable folder on PATH"
    }

    // MARK: Double-Shift → Search Everywhere

    private func installDoubleShift() {
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in
            guard let self else { return e }
            if e.type == .keyDown { self.shiftClean = false; self.lastShift = nil; return e }
            let shiftOnly = e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift
            let released = e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            if shiftOnly { self.shiftClean = true }
            else if released && self.shiftClean && (e.keyCode == 56 || e.keyCode == 60) {
                self.shiftClean = false
                if let last = self.lastShift, Date().timeIntervalSince(last) < 0.4 {
                    self.lastShift = nil
                    if let c = self.controllers.first(where: { $0.window?.isKeyWindow == true }) { c.searchEverywhere(nil) }
                } else {
                    self.lastShift = Date()
                }
            } else if !released { self.shiftClean = false }
            return e
        }
    }

    @objc func showSettings(_ sender: Any?) { SettingsWindow.show() }
    @objc func showAISettings(_ sender: Any?) { AISettingsView.show() }
    @objc func connectPostgres(_ sender: Any?) { DatabaseModel.connectPostgres() }
    @objc func openRemote(_ sender: Any?) { RemoteConnect.show() }
    @objc func openDatabaseFile(_ sender: Any?) {
        let p = NSOpenPanel(); p.allowedContentTypes = [.data]; p.message = "Choose a SQLite database file"
        guard p.runModal() == .OK, let u = p.url else { return }
        guard u.isDatabase else { let a = NSAlert(); a.messageText = "That isn't a SQLite database."; a.runModal(); return }
        DatabaseModel.show(DatabaseModel(file: u), title: u.lastPathComponent)
    }
    @objc func toggleInlineCompletions(_ sender: Any?) {
        let on = !UserDefaults.standard.bool(forKey: "aiInlineCompletions")
        UserDefaults.standard.set(on, forKey: "aiInlineCompletions")
        if on && !AIConfig.isConfigured { AISettingsView.show() }
    }
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleInlineCompletions(_:)) { item.state = UserDefaults.standard.bool(forKey: "aiInlineCompletions") ? .on : .off }
        return true
    }
    @objc func showWelcome(_ sender: Any?) { WelcomeWindow.show() }
    @objc func showHelp(_ sender: Any?) { HelpWindow.show(.start) }
    @objc func showShortcuts(_ sender: Any?) { HelpWindow.show(.shortcuts) }
    @objc func showTemplatesHelp(_ sender: Any?) { HelpWindow.show(.templates) }
    @objc func showLanguageSettings(_ sender: Any?) { SettingsWindow.show() }
    @objc func installCLIFromMenu(_ sender: Any?) {
        let a = NSAlert(); a.messageText = installCLI(); a.informativeText = "Open projects from Terminal with: zide ."; a.runModal()
    }
}
