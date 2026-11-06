import AppKit
import Combine

final class FileNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    var children: [FileNode]?
    var id: URL { url }
    var name: String { url.lastPathComponent }

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    static func == (a: FileNode, b: FileNode) -> Bool { a.url == b.url }
    func hash(into h: inout Hasher) { h.combine(url) }

    static let hiddenNames: Set<String> = [".git", ".DS_Store", ".svn", ".hg"]
    static let dimmedNames: Set<String> = ["node_modules", ".build", "build", "dist", "target", "DerivedData", ".gradle", ".idea",
                                           "__pycache__", ".venv", "venv", "Pods", ".next", ".nuxt", "out", ".swiftpm", ".cache", "coverage", ".turbo"]

    func loadChildren() -> [FileNode] {
        if let children { return children }
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [])) ?? []
        let nodes = items.filter { !Self.hiddenNames.contains($0.lastPathComponent) }.map { u -> FileNode in
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let dir = (v?.isDirectory ?? false) && !(v?.isPackage ?? false && !u.pathExtension.isEmpty && u.pathExtension != "xcodeproj" && u.pathExtension != "xcworkspace")
            return FileNode(url: u, isDirectory: dir)
        }.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        children = nodes
        return nodes
    }

    func invalidate() {
        guard let children else { return }
        let old = Dictionary(uniqueKeysWithValues: children.map { ($0.url, $0) })
        self.children = nil
        // Keep already-loaded grandchildren so expanded folders stay expanded.
        for c in loadChildren() { if let prev = old[c.url], prev.isDirectory { c.children = prev.children; c.invalidate() } }
    }
}

struct TreeRow: Identifiable {
    let node: FileNode
    let depth: Int
    var id: URL { node.url }
}

enum SidebarTab: String, CaseIterable { case project = "Project", commit = "Commit", structure = "Structure" }
enum BottomTab: String, CaseIterable { case terminal = "Terminal", run = "Run", debug = "Debug", problems = "Problems", find = "Find", todo = "TODO", git = "Git Log" }

/// One side of a split: its own tabs and current document.
@MainActor
final class EditorPane: ObservableObject, Identifiable {
    let id = UUID()
    @Published var tabs: [EditorDocument] = []
    @Published var active: EditorDocument?
}

struct UsageGroup: Identifiable {
    let url: URL
    var items: [UsageItem]
    var id: URL { url }
}

struct UsageItem: Identifiable {
    let id = UUID()
    let url: URL
    let line: Int        // 0-based
    let column: Int      // 0-based (UTF-16)
    let length: Int
    let preview: String
}

@MainActor
final class Workspace: ObservableObject {
    let root: URL
    /// Opened for a single file outside any repository (the TextEdit use): no sidebar, no restored tabs, lazy index.
    let quickFile: URL?
    var isQuick: Bool { quickFile != nil }
    var name: String { root.lastPathComponent }

    /// Every open document (union of all split panes' tabs).
    @Published private(set) var documents: [EditorDocument] = []
    @Published private(set) var panes: [EditorPane] = [EditorPane()]
    @Published var focusedPane = 0 { didSet { if oldValue != focusedPane { activeChanged() } } }

    /// The focused pane's current document.
    var active: EditorDocument? {
        get { panes[min(focusedPane, panes.count - 1)].active }
        set {
            objectWillChange.send()
            let pane = panes[min(focusedPane, panes.count - 1)]
            if let d = newValue, !pane.tabs.contains(where: { $0 === d }) {
                if let i = pane.tabs.firstIndex(where: { $0 === pane.active }) { pane.tabs.insert(d, at: i + 1) } else { pane.tabs.append(d) }
            }
            pane.active = newValue
            activeChanged()
        }
    }

    var isSplit: Bool { panes.count > 1 }

    /// Which pane the document is visible in (prefers the focused pane).
    func pane(showing doc: EditorDocument) -> Int {
        if panes.indices.contains(focusedPane), panes[focusedPane].active === doc { return focusedPane }
        return panes.firstIndex { $0.active === doc } ?? panes.firstIndex { $0.tabs.contains { $0 === doc } } ?? 0
    }
    @Published var expanded: Set<URL> = []
    @Published private(set) var rows: [TreeRow] = []
    @Published var selectedFile: URL?
    @Published var sidebarTab: SidebarTab = .project
    @Published var sidebarVisible = true
    /// Distraction-free: only the text, centred.
    @Published var zen = false
    @Published var bottomTab: BottomTab = .terminal
    @Published var bottomVisible = false
    @Published var flashMessage: String?
    @Published var problems: [URL: [Diagnostic]] = [:]
    @Published var usagesTitle = ""
    @Published var usages: [UsageGroup] = []
    @Published var symbols: [DocSymbol] = []
    @Published private(set) var fileIndex: [String] = []   // relative paths
    @Published var markdownPreview = false
    /// The AI assistant panel on the right.
    @Published var assistantVisible = false
    /// Live preview beside HTML / CSS / JS files.
    @Published var livePreview = false
    /// Show .ipynb files as raw JSON instead of the notebook view.
    @Published var notebookAsText = false
    @Published private(set) var todos: [UsageGroup] = []

    lazy var lsp = LSPManager(workspace: self)
    lazy var git = GitModel(workspace: self)
    lazy var runner = RunManager(workspace: self)
    lazy var terminals = TerminalManager(workspace: self)
    lazy var search = SearchModel(workspace: self)
    lazy var palette = PaletteModel(workspace: self)
    lazy var debug = DebugManager(workspace: self)
    lazy var bookmarks = Bookmarks(workspace: self)
    lazy var assistant = AssistantModel(workspace: self)
    lazy var preview = PreviewModel(workspace: self)
    /// Set when this folder is a local copy of a folder on an SSH server.
    lazy var remote: RemoteSession? = Remote.spec(for: root).map { RemoteSession(spec: $0, workspace: self) }
    private let tree: FileNode
    private var watcher: FileWatcher?
    private var flashTimer: Timer?
    private var recentFiles: [URL] = []
    private var navBack: [(URL, Int)] = []
    private var navForward: [(URL, Int)] = []
    private var symbolTimer: Timer?
    private var autosaveTimer: Timer?
    weak var window: NSWindow?

    init(root: URL, quickFile: URL? = nil) {
        self.root = root.standardizedFileURL
        self.quickFile = quickFile?.standardizedFileURL
        tree = FileNode(url: self.root, isDirectory: true)
        expanded = [self.root]
        rebuildRows()
        watcher = FileWatcher(url: self.root) { [weak self] paths in
            MainActor.assumeIsolated { self?.filesChanged(paths) }
        }
        if let quickFile {
            // A note in Downloads shouldn't index the whole folder before it appears.
            sidebarVisible = false
            open(quickFile, focus: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.rebuildIndex(); self?.git.refresh() }
        } else {
            rebuildIndex()
            git.refresh()
            for path in Prefs.shared.openFiles(for: self.root) where FileManager.default.fileExists(atPath: path) {
                open(URL(fileURLWithPath: path), focus: false)
            }
        }
        runner.detect()
        if let last = documents.last { active = last }
        panes[0].tabs = documents
    }

    func close() {
        persistOpenFiles()
        saveAll()
        for d in documents { Prefs.shared.setCaret(d.primaryEditor.textView.selectedRange().location, for: d.url) }
        debug.stop()
        lsp.stopAll()
        terminals.closeAll()
        runner.stop()
        watcher = nil
    }

    // MARK: File tree

    func rebuildRows() {
        var out: [TreeRow] = []
        func walk(_ n: FileNode, _ depth: Int) {
            for c in n.loadChildren() {
                out.append(TreeRow(node: c, depth: depth))
                if c.isDirectory && expanded.contains(c.url) { walk(c, depth + 1) }
            }
        }
        walk(tree, 0)
        rows = out
    }

    func toggle(_ node: FileNode) {
        if expanded.contains(node.url) { expanded.remove(node.url) } else { expanded.insert(node.url) }
        rebuildRows()
    }

    /// Expands parents and selects the file in the project tree.
    func reveal(_ url: URL) {
        var dir = url.deletingLastPathComponent().standardizedFileURL
        while dir.path.hasPrefix(root.path) && dir != root {
            expanded.insert(dir)
            dir = dir.deletingLastPathComponent()
        }
        rebuildRows()
        selectedFile = url
        sidebarTab = .project
        sidebarVisible = true
    }

    private func filesChanged(_ paths: [String]) {
        let interesting = paths.filter { !$0.contains("/.git/") || $0.hasSuffix("/.git/HEAD") || $0.hasSuffix("/.git/index") }
        guard !interesting.isEmpty else { return }
        tree.invalidate()
        rebuildRows()
        for d in documents { d.reloadIfChangedOnDisk() }
        git.refresh()
        if paths.contains(where: { !$0.contains("/.git/") }) { rebuildIndex() }
    }

    func rebuildIndex() {
        let root = self.root
        Task.detached(priority: .utility) {
            var files: [String] = []
            if Env.which("rg") != nil {
                let r = Shell.run("rg", ["--files", "--hidden", "-g", "!.git"], cwd: root)
                files = r.out.split(separator: "\n").map(String.init)
            }
            if files.isEmpty {
                let fm = FileManager.default
                let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants])
                let prefix = root.path.count + 1
                while let u = e?.nextObject() as? URL, files.count < 100_000 {
                    let n = u.lastPathComponent
                    if FileNode.hiddenNames.contains(n) || FileNode.dimmedNames.contains(n) { e?.skipDescendants(); continue }
                    if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false { files.append(String(u.path.dropFirst(prefix))) }
                }
            }
            files.sort { $0.count < $1.count }
            await MainActor.run { self.fileIndex = files }
        }
    }

    // MARK: Documents

    @discardableResult
    func open(_ url: URL, range: JSON? = nil, selection: NSRange? = nil, focus: Bool = true) -> EditorDocument? {
        let url = url.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        let doc: EditorDocument
        if let existing = documents.first(where: { $0.url == url }) {
            doc = existing
        } else {
            doc = EditorDocument(url: url)
            doc.workspace = self
            Prefs.shared.addRecentFile(url)
            documents.append(doc)
            lsp.didOpen(doc)
            git.loadLineChanges(doc)
            persistOpenFiles()
            if range == nil && selection == nil, let caret = Prefs.shared.caret(for: url), caret <= doc.storage.length {
                DispatchQueue.main.async { doc.editor.select(NSRange(location: caret, length: 0)) }
            }
        }
        active = doc
        recentFiles.removeAll { $0 == url }
        recentFiles.insert(url, at: 0)
        if let range, let r = doc.lineIndex.range(range) {
            DispatchQueue.main.async { doc.editor.select(NSRange(location: r.location, length: 0)) }
        } else if let selection {
            DispatchQueue.main.async { doc.editor.select(selection) }
        }
        if focus { DispatchQueue.main.async { doc.editor.textView.window?.makeFirstResponder(doc.editor.textView) } }
        return doc
    }

    /// Closes the document's tab in `pane` (default: the focused pane); the file closes when no pane shows it.
    /// Recently closed files, newest last (⇧⌘T reopens).
    private(set) var closedFiles: [URL] = []
    func reopenClosed() {
        while let u = closedFiles.popLast() {
            if FileManager.default.fileExists(atPath: u.path) { open(u); return }
        }
        flash("No recently closed tabs")
    }

    func closeDocument(_ doc: EditorDocument, force: Bool = false, pane paneIndex: Int? = nil) {
        if !doc.isBinary { closedFiles.removeAll { $0 == doc.url }; closedFiles.append(doc.url); if closedFiles.count > 30 { closedFiles.removeFirst() } }
        let idx = paneIndex ?? (panes[focusedPane].tabs.contains { $0 === doc } ? focusedPane : (panes.firstIndex { $0.tabs.contains { $0 === doc } } ?? focusedPane))
        let pane = panes[idx]
        let stillShownElsewhere = panes.enumerated().contains { $0.offset != idx && $0.element.tabs.contains { $0 === doc } }
        if !stillShownElsewhere && doc.isDirty && !force {
            if Prefs.shared.autosave { doc.save() } else {
                let a = NSAlert()
                a.messageText = "Save changes to \(doc.name)?"
                a.addButton(withTitle: "Save"); a.addButton(withTitle: "Don't Save"); a.addButton(withTitle: "Cancel")
                switch a.runModal() {
                case .alertFirstButtonReturn: doc.save()
                case .alertSecondButtonReturn: break
                default: return
                }
            }
        }
        objectWillChange.send()
        let tabIdx = pane.tabs.firstIndex { $0 === doc }
        pane.tabs.removeAll { $0 === doc }
        if pane.active === doc {
            pane.active = recentFiles.lazy.compactMap { u in pane.tabs.first { $0.url == u } }.first
                ?? tabIdx.flatMap { pane.tabs.indices.contains(max(0, $0 - 1)) ? pane.tabs[max(0, $0 - 1)] : pane.tabs.first }
        }
        if idx == 1 { doc.dropSecondary() }
        if !stillShownElsewhere {
            Prefs.shared.setCaret(doc.primaryEditor.textView.selectedRange().location, for: doc.url)
            doc.editors.forEach { $0.completion.hide(); $0.info.hide() }
            lsp.didClose(doc)
            documents.removeAll { $0 === doc }
        }
        if isSplit && pane.tabs.isEmpty { unsplit() }
        activeChanged()
        persistOpenFiles()
    }

    func closeOthers(_ doc: EditorDocument) { for d in panes[focusedPane].tabs where d !== doc { closeDocument(d, pane: focusedPane) } }
    func closeAll() { for p in panes.indices.reversed() where p < panes.count { for d in panes[p].tabs { closeDocument(d, pane: min(p, panes.count - 1)) } } }

    private func persistOpenFiles() { Prefs.shared.setOpenFiles(documents.map(\.url.path), for: root) }

    // MARK: Split editors

    /// Splits right, showing the current file in both panes (like JetBrains "Split Right").
    func splitRight() {
        guard !isSplit else { focusedPane = focusedPane == 0 ? 1 : 0; focusActiveEditor(); return }
        let p = EditorPane()
        if let a = active { p.tabs = [a]; p.active = a }
        panes.append(p)
        focusedPane = 1
        focusActiveEditor()
    }

    func unsplit() {
        guard isSplit else { return }
        let right = panes[1]
        for d in right.tabs where !panes[0].tabs.contains(where: { $0 === d }) { panes[0].tabs.append(d) }
        if focusedPane == 1, let a = right.active { panes[0].active = a }
        for d in documents { d.dropSecondary() }
        panes.removeLast()
        focusedPane = 0
        activeChanged()
        focusActiveEditor()
    }

    /// Moves the current tab to the other pane (splitting first if needed).
    func moveToOtherSplit() {
        guard let doc = active else { return }
        if !isSplit {
            panes.append(EditorPane())
        }
        let from = focusedPane, to = focusedPane == 0 ? 1 : 0
        let target = panes[to]
        if !target.tabs.contains(where: { $0 === doc }) { target.tabs.append(doc) }
        target.active = doc
        let src = panes[from]
        src.tabs.removeAll { $0 === doc }
        if src.active === doc { src.active = src.tabs.last }
        if from == 1 { doc.dropSecondary() }
        focusedPane = to
        if panes[1].tabs.isEmpty { unsplit() } else if panes[0].tabs.isEmpty {
            // Left pane emptied: shift the right pane over.
            for d in documents { d.dropSecondary() }
            panes.removeFirst(); focusedPane = 0
        }
        objectWillChange.send()
        focusActiveEditor()
    }

    func focusOtherSplit() {
        guard isSplit else { return }
        focusedPane = focusedPane == 0 ? 1 : 0
        focusActiveEditor()
    }

    func focusActiveEditor() {
        DispatchQueue.main.async {
            guard let doc = self.active else { return }
            let tv = doc.editor(pane: self.focusedPane).textView
            tv.window?.makeFirstResponder(tv)
        }
    }

    func saveAll() {
        for d in documents where d.isDirty { d.save() }
    }

    func save(_ doc: EditorDocument) {
        NotificationCenter.default.post(name: .zideWillSave, object: doc)     // notebooks write their cells first
        if doc.url.pathExtension.lowercased() == "ipynb" || doc.isBinary { doc.save(); return }
        if Prefs.shared.formatOnSave { doc.editor.format { doc.save() } } else { doc.save() }
    }

    func documentEdited(_ doc: EditorDocument) {
        guard Prefs.shared.autosave else { return }
        // JetBrains-style: save a few seconds after typing stops.
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveAll() }
        }
    }

    func documentSaved(_ doc: EditorDocument) {
        lsp.didSave(doc)
        git.refresh()
        git.loadLineChanges(doc)
        LocalHistory.snapshot(doc.url, text: doc.text, root: root)
        remote?.saved(doc.url)
    }

    private func activeChanged() {
        symbols = []
        scheduleSymbols()
        if let a = active { selectedFile = a.url }
    }

    func scheduleSymbols() {
        symbolTimer?.invalidate()
        guard sidebarTab == .structure, let doc = active else { return }
        symbolTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                Task { @MainActor in
                    guard let self else { return }
                    self.symbols = await self.documentSymbols(doc)
                }
            }
        }
    }

    // MARK: Navigation

    func pushNavigation() {
        guard let doc = active else { return }
        navBack.append((doc.url, doc.editor.textView.selectedRange().location))
        if navBack.count > 100 { navBack.removeFirst() }
        navForward = []
    }

    func goBack() {
        guard let (url, off) = navBack.popLast() else { return }
        if let doc = active { navForward.append((doc.url, doc.editor.textView.selectedRange().location)) }
        open(url, selection: NSRange(location: off, length: 0))
    }

    func goForward() {
        guard let (url, off) = navForward.popLast() else { return }
        if let doc = active { navBack.append((doc.url, doc.editor.textView.selectedRange().location)) }
        open(url, selection: NSRange(location: off, length: 0))
    }

    var recentFileURLs: [URL] { recentFiles }

    func relative(_ url: URL) -> String {
        let p = url.standardizedFileURL.path
        return p.hasPrefix(root.path + "/") ? String(p.dropFirst(root.path.count + 1)) : (p as NSString).abbreviatingWithTildeInPath
    }

    // MARK: Diagnostics

    func setDiagnostics(url: URL, raw: [JSON]) {
        let url = url.standardizedFileURL
        let doc = documents.first { $0.url == url }
        let index: LineIndex
        if let doc { index = doc.lineIndex } else if let text = try? String(contentsOf: url, encoding: .utf8) { index = LineIndex(text as NSString) } else { index = LineIndex("" as NSString) }
        let diags: [Diagnostic] = raw.compactMap { d in
            guard let r = d["range"] as? JSON, let range = index.range(r), let start = r["start"] as? JSON else { return nil }
            let source = d["source"] as? String
            let code = (d["code"] as? String) ?? (d["code"] as? Int).map(String.init)
            return Diagnostic(range: range, line: start["line"] as? Int ?? 0, column: start["character"] as? Int ?? 0,
                              severity: Diagnostic.Severity(rawValue: d["severity"] as? Int ?? 1) ?? .error,
                              message: (d["message"] as? String ?? "") + (code.map { " [\($0)]" } ?? ""), source: source)
        }
        problems[url] = diags.isEmpty ? nil : diags
        if let doc {
            doc.diagnostics = diags
            doc.editors.forEach { $0.applyDiagnostics() }
        }
    }

    var problemCounts: (errors: Int, warnings: Int) {
        var e = 0, w = 0
        for list in problems.values { for d in list { if d.severity == .error { e += 1 } else if d.severity == .warning { w += 1 } } }
        return (e, w)
    }

    // MARK: Edits from the language server

    func apply(workspaceEdit edit: JSON) {
        var perFile: [(URL, [JSON])] = []
        if let changes = edit["changes"] as? [String: [JSON]] {
            for (uri, edits) in changes { if let u = URL(string: uri) { perFile.append((u, edits)) } }
        }
        for change in (edit["documentChanges"] as? [JSON]) ?? [] {
            if let td = change["textDocument"] as? JSON, let uri = td["uri"] as? String, let u = URL(string: uri) {
                perFile.append((u, change["edits"] as? [JSON] ?? []))
            } else if let kind = change["kind"] as? String {
                let fm = FileManager.default
                switch kind {
                case "create": if let uri = change["uri"] as? String, let u = URL(string: uri) { fm.createFile(atPath: u.path, contents: nil) }
                case "rename":
                    if let o = (change["oldUri"] as? String).flatMap(URL.init(string:)), let n = (change["newUri"] as? String).flatMap(URL.init(string:)) {
                        try? fm.moveItem(at: o, to: n)
                        documents.first { $0.url == o.standardizedFileURL }?.rename(to: n)
                    }
                default: break
                }
            }
        }
        var count = 0
        for (url, edits) in perFile where !edits.isEmpty {
            let wasOpen = documents.contains { $0.url == url.standardizedFileURL }
            guard let doc = open(url, focus: false) else { continue }
            doc.apply(edits: edits)
            count += edits.count
            if !wasOpen { doc.save() }
        }
        if count > 0 { flash("Applied \(count) change\(count == 1 ? "" : "s") in \(perFile.count) file\(perFile.count == 1 ? "" : "s")") }
    }

    func documentSymbols(_ doc: EditorDocument) async -> [DocSymbol] {
        guard let r = await lsp.request("textDocument/documentSymbol", doc, params: [:]) as? [JSON], !r.isEmpty else { return MarkdownOutline.symbols(doc) }
        let idx = doc.lineIndex
        var out: [DocSymbol] = []
        func walk(_ items: [JSON], depth: Int) {
            for s in items {
                let rangeJSON = (s["selectionRange"] as? JSON) ?? (s["range"] as? JSON) ?? ((s["location"] as? JSON)?["range"] as? JSON)
                guard let range = idx.range(rangeJSON) else { continue }
                out.append(DocSymbol(name: s["name"] as? String ?? "", detail: s["detail"] as? String ?? (s["containerName"] as? String ?? ""),
                                     kind: s["kind"] as? Int ?? 0, range: range, depth: depth))
                if let kids = s["children"] as? [JSON] { walk(kids, depth: depth + 1) }
            }
        }
        walk(r, depth: 0)
        return out
    }

    // MARK: Usages / find

    func showUsages(title: String, _ locations: [(URL, JSON)]) {
        var groups: [URL: [UsageItem]] = [:]
        for (url, range) in locations {
            let u = url.standardizedFileURL
            let start = range["start"] as? JSON ?? [:], end = range["end"] as? JSON ?? [:]
            let line = start["line"] as? Int ?? 0, col = start["character"] as? Int ?? 0
            let text: String
            if let doc = documents.first(where: { $0.url == u }) {
                let idx = doc.lineIndex
                let a = idx.offset(line: line, character: 0), b = idx.offset(line: line + 1, character: 0)
                text = (doc.text as NSString).substring(with: NSRange(location: a, length: max(0, b - a)))
            } else {
                text = Self.line(line, of: u)
            }
            let len = (end["line"] as? Int ?? line) == line ? max(0, (end["character"] as? Int ?? col) - col) : 0
            groups[u, default: []].append(UsageItem(url: u, line: line, column: col, length: len, preview: text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        usagesTitle = "\(title) — \(locations.count) result\(locations.count == 1 ? "" : "s")"
        usages = groups.map { UsageGroup(url: $0.key, items: $0.value.sorted { $0.line < $1.line }) }.sorted { relative($0.url) < relative($1.url) }
        bottomTab = .find
        bottomVisible = true
        if locations.count == 1, let only = usages.first?.items.first { openUsage(only) }
    }

    nonisolated static func line(_ n: Int, of url: URL) -> String {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        var i = 0
        for l in s.split(separator: "\n", omittingEmptySubsequences: false) { if i == n { return String(l) }; i += 1 }
        return ""
    }

    func openUsage(_ u: UsageItem) {
        pushNavigation()
        guard let doc = open(u.url) else { return }
        let off = doc.lineIndex.offset(line: u.line, character: u.column)
        DispatchQueue.main.async { doc.editor.select(NSRange(location: off, length: u.length)) }
    }

    func findInFiles(_ query: String, wholeWord: Bool = false) {
        search.query = query
        search.wholeWord = wholeWord
        bottomTab = .find
        bottomVisible = true
        search.run()
    }

    /// Scans the project for TODO / FIXME / HACK comments.
    func scanTodos() {
        let root = self.root
        Task.detached(priority: .utility) {
            let r = Shell.run("rg", ["--line-number", "--column", "--no-heading", "--color", "never", "--max-columns", "240", "-e", "\\b(TODO|FIXME|HACK|XXX)\\b", "."], cwd: root)
            var groups: [URL: [UsageItem]] = [:]
            for line in r.out.split(separator: "\n").prefix(3000) {
                let parts = line.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
                guard parts.count == 4, let ln = Int(parts[1]), let col = Int(parts[2]) else { continue }
                var path = String(parts[0]); if path.hasPrefix("./") { path.removeFirst(2) }
                let url = root.appendingPathComponent(path).standardizedFileURL
                groups[url, default: []].append(UsageItem(url: url, line: ln - 1, column: col - 1, length: 4, preview: parts[3].trimmingCharacters(in: .whitespaces)))
            }
            let sorted = groups.map { UsageGroup(url: $0.key, items: $0.value) }.sorted { $0.url.path < $1.url.path }
            await MainActor.run { self.todos = sorted }
        }
    }

    // MARK: Messages

    func flash(_ message: String) {
        flashMessage = message
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flashMessage = nil }
        }
    }

    func lspHint(for lang: Language, feature: String) -> String {
        switch lsp.status(for: lang) {
        case .missing(let spec): return "\(feature) needs a \(lang.name) language server — install with: \(spec.install)"
        case .starting: return "\(lang.name) language server is starting…"
        case .failed(let cmd, _): return "\(cmd) failed to start — see Settings › Languages"
        case .none: return "\(feature) isn't available for \(lang.name) files"
        case .ready: return "\(feature) isn't supported by the \(lang.name) language server"
        }
    }

    // MARK: File operations (from the project tree)

    func newFile(in dir: URL, folder: Bool = false) {
        let a = NSAlert()
        a.messageText = folder ? "New Folder" : "New File"
        a.informativeText = folder ? "Folder name" : "File name (use / to create folders, e.g. src/util.ts)"
        let field = NSTextField(string: "")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: "Create"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let url = dir.appendingPathComponent(name)
        let fm = FileManager.default
        do {
            if folder {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard !fm.fileExists(atPath: url.path) else { open(url); return }
                fm.createFile(atPath: url.path, contents: Data())
            }
            tree.invalidate()
            reveal(url)
            if !folder { open(url) }
            git.refresh()
        } catch { NSAlert(error: error).runModal() }
    }

    func rename(_ url: URL) {
        let a = NSAlert()
        a.messageText = "Rename"
        let field = NSTextField(string: url.lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: "Rename"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != url.lastPathComponent else { return }
        let dest = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            for d in documents where d.url == url.standardizedFileURL { d.rename(to: dest.standardizedFileURL) }
            for d in documents where d.url.path.hasPrefix(url.path + "/") {
                d.rename(to: URL(fileURLWithPath: dest.path + d.url.path.dropFirst(url.path.count)))
            }
            tree.invalidate()
            reveal(dest)
        } catch { NSAlert(error: error).runModal() }
    }

    /// Moves to the Trash (recoverable) after confirmation.
    func trash(_ url: URL) {
        let a = NSAlert()
        a.messageText = "Move \(url.lastPathComponent) to the Trash?"
        a.informativeText = "You can restore it from the Trash."
        a.addButton(withTitle: "Move to Trash"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.recycle([url]) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error { NSAlert(error: error).runModal(); return }
                for d in self.documents where d.url == url.standardizedFileURL || d.url.path.hasPrefix(url.path + "/") { self.closeDocument(d, force: true) }
                self.tree.invalidate()
                self.rebuildRows()
            }
        }
    }
}

struct DocSymbol: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
    let kind: Int
    let range: NSRange
    let depth: Int
}

/// FSEvents wrapper that reports changed paths (debounced).
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let callback: ([String]) -> Void
    private var pending: [String] = []
    private var timer: DispatchWorkItem?

    init(url: URL, callback: @escaping ([String]) -> Void) {
        self.callback = callback
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            me.received(Array(arr.prefix(count)))
        }, &ctx, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
           FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    private func received(_ paths: [String]) {
        pending += paths
        timer?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let p = self.pending
            self.pending = []
            self.callback(p)
        }
        timer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
