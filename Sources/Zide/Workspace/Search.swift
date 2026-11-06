import AppKit
import SwiftUI

/// Find / Replace in Files (ripgrep when available).
@MainActor
final class SearchModel: ObservableObject {
    unowned let workspace: Workspace
    @Published var query = ""
    @Published var replacement = ""
    @Published var caseSensitive = false
    @Published var wholeWord = false
    @Published var regex = false
    @Published var fileMask = ""
    @Published var showReplace = false
    @Published private(set) var running = false
    @Published private(set) var summary = ""
    private var task: Task<Void, Never>?

    init(workspace: Workspace) { self.workspace = workspace }

    func run() {
        let q = query
        guard !q.isEmpty else { return }
        task?.cancel()
        running = true
        let root = workspace.root
        let opts = (caseSensitive, wholeWord, regex, fileMask)
        task = Task.detached(priority: .userInitiated) {
            var args = ["--line-number", "--column", "--no-heading", "--color", "never", "--max-columns", "300", "--max-count", "500", "-H"]
            if !opts.0 { args.append("--ignore-case") }
            if opts.1 { args.append("--word-regexp") }
            if !opts.2 { args.append("--fixed-strings") }
            if !opts.3.isEmpty { for m in opts.3.split(separator: ",") { args += ["-g", m.trimmingCharacters(in: .whitespaces)] } }
            args += ["--", q, "."]
            var r = Shell.run("rg", args, cwd: root)
            if r.status == 127 {
                var g = ["-rnI", "--exclude-dir=.git", "--exclude-dir=node_modules"]
                if !opts.0 { g.append("-i") }
                if opts.1 { g.append("-w") }
                if !opts.2 { g.append("-F") }
                r = Shell.run("grep", g + ["--", q, "."], cwd: root)
            }
            var groups: [URL: [UsageItem]] = [:]
            var total = 0
            for line in r.out.split(separator: "\n") where total < 5000 {
                // path:line:col:text  (grep has no column)
                let parts = line.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
                guard parts.count >= 3, let ln = Int(parts[1]) else { continue }
                var col = 0, text = ""
                if parts.count == 4, let c = Int(parts[2]) { col = c - 1; text = String(parts[3]) } else { text = parts.dropFirst(2).joined(separator: ":") }
                var path = String(parts[0])
                if path.hasPrefix("./") { path.removeFirst(2) }
                let url = root.appendingPathComponent(path).standardizedFileURL
                let utf16Col = text.utf8.count > col ? (String(decoding: Array(text.utf8.prefix(col)), as: UTF8.self) as NSString).length : col
                groups[url, default: []].append(UsageItem(url: url, line: ln - 1, column: utf16Col, length: (q as NSString).length,
                                                          preview: text.trimmingCharacters(in: .whitespaces)))
                total += 1
            }
            let sorted = groups.map { UsageGroup(url: $0.key, items: $0.value) }.sorted { $0.url.path < $1.url.path }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.running = false
                self.workspace.usagesTitle = "\(total) match\(total == 1 ? "" : "es") for “\(q)” in \(sorted.count) file\(sorted.count == 1 ? "" : "s")"
                self.workspace.usages = sorted
                self.summary = self.workspace.usagesTitle
            }
        }
    }

    /// Replaces the matches shown in the results after a preview where each change can be unticked
    /// (regex replacements support $1, $2… groups). Open files are edited through the editor, so it's undoable.
    func replaceAll() {
        let groups = workspace.usages
        guard groups.reduce(0, { $0 + $1.items.count }) > 0 else { return }
        var items: [ReplacePreviewItem] = []
        let re = regex ? try? NSRegularExpression(pattern: query, options: caseSensitive ? [] : [.caseInsensitive]) : nil
        if regex && re == nil { workspace.flash("That regular expression isn't valid"); return }
        for g in groups {
            guard let doc = workspace.open(g.url, focus: false) else { continue }
            let idx = doc.lineIndex
            let ns = doc.text as NSString
            for item in g.items {
                let r = NSRange(location: idx.offset(line: item.line, character: item.column), length: item.length)
                guard NSMaxRange(r) <= ns.length else { continue }
                let lineR = ns.lineRange(for: r)
                let lineText = ns.substring(with: lineR).trimmingCharacters(in: .newlines)
                var edit = (r, replacement)
                if let re {
                    guard let m = re.firstMatch(in: ns as String, range: NSRange(location: r.location, length: NSMaxRange(lineR) - r.location)) else { continue }
                    edit = (m.range, re.replacementString(for: m, in: ns as String, offset: 0, template: replacement))
                }
                let local = NSRange(location: edit.0.location - lineR.location, length: edit.0.length)
                guard NSMaxRange(local) <= (lineText as NSString).length else { continue }
                let after = (lineText as NSString).replacingCharacters(in: local, with: edit.1)
                items.append(ReplacePreviewItem(file: g.url, line: item.line + 1, before: lineText.trimmingCharacters(in: .whitespaces),
                                                after: after.trimmingCharacters(in: .whitespaces), edit: edit))
            }
        }
        guard !items.isEmpty, let chosen = ReplacePreviewModel.run(items: items, title: "Replace “\(query)” with “\(replacement)” in \(Set(items.map(\.file)).count) file(s)") else { return }
        for (file, edits) in Dictionary(grouping: chosen, by: \.file) {
            guard let doc = workspace.open(file, focus: false) else { continue }
            doc.editor.replace(edits.map(\.edit))
        }
        workspace.saveAll()
        workspace.flash("Replaced \(chosen.count) occurrence\(chosen.count == 1 ? "" : "s")")
        run()
    }
}

// MARK: - Palette (Search Everywhere, Find Action, Recent Files, File Structure)

struct PaletteItem: Identifiable {
    let id = UUID()
    var title: String
    var subtitle: String = ""
    var icon: String = "doc"
    var indent: Int = 0
    var shortcut: String = ""
    var iconColor: Color = .secondary
    var score = 0
    let action: () -> Void
}

struct PaletteAction {
    let title: String
    let shortcut: String
    let icon: String
    let run: () -> Void
}

@MainActor
final class PaletteModel: ObservableObject {
    enum Mode: String, CaseIterable { case all = "All", files = "Files", symbols = "Symbols", actions = "Actions", text = "Text", tasks = "Tasks", custom = "" }

    unowned let workspace: Workspace
    @Published var visible = false
    @Published var mode: Mode = .all
    @Published var query = "" { didSet { update() } }
    @Published private(set) var results: [PaletteItem] = []
    @Published var selected = 0
    @Published var title = ""
    private var customItems: [PaletteItem] = []
    private var symbolResults: [PaletteItem] = []
    private var symbolTask: Task<Void, Never>?
    var actions: [PaletteAction] = []

    init(workspace: Workspace) { self.workspace = workspace }

    func open(_ mode: Mode) {
        self.mode = mode
        title = ""
        customItems = []
        if mode == .files, visible, self.mode == .files { self.mode = .all }
        query = ""
        visible = true
        update()
    }

    func show(title: String, items: [PaletteItem]) {
        mode = .custom
        self.title = title
        customItems = items
        query = ""
        visible = true
        update()
    }

    func showRecentFiles() {
        let items = workspace.recentFileURLs.dropFirst().prefix(30).map { url in
            PaletteItem(title: url.lastPathComponent, subtitle: workspace.relative(url.deletingLastPathComponent()),
                        icon: FileIcon.symbol(url), iconColor: FileIcon.color(url)) { [weak self] in self?.workspace.open(url) }
        }
        show(title: "Recent Files", items: Array(items))
    }

    func close() {
        visible = false
        symbolTask?.cancel()
        DispatchQueue.main.async {
            if let tv = self.workspace.active?.editor.textView { tv.window?.makeFirstResponder(tv) }
        }
    }

    func cycleMode() {
        guard mode != .custom else { return }
        let modes: [Mode] = [.all, .files, .symbols, .actions, .text, .tasks]
        mode = modes[((modes.firstIndex(of: mode) ?? 0) + 1) % modes.count]
        update()
    }

    func move(_ d: Int) { selected = max(0, min(results.count - 1, selected + d)) }

    func accept() {
        guard results.indices.contains(selected) else { return }
        let item = results[selected]
        close()
        item.action()
    }

    private func update() {
        selected = 0
        let q = query.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .custom:
            results = filter(customItems, q, keepOrder: q.isEmpty)
        case .files:
            results = fileResults(q, limit: 100)
        case .actions:
            results = actionResults(q)
        case .symbols:
            results = symbolResults
            searchSymbols(q)
        case .text:
            results = textResults
            searchText(q)
        case .tasks:
            results = filter(taskItems(), q, keepOrder: true)
        case .all:
            var out = fileResults(q, limit: q.isEmpty ? 15 : 30)
            if !q.isEmpty { out += actionResults(q).prefix(8); out += filter(taskItems(), q, keepOrder: true).prefix(4) }
            results = out + symbolResults.prefix(15)
            searchSymbols(q)
        }
    }

    private func filter(_ items: [PaletteItem], _ q: String, keepOrder: Bool) -> [PaletteItem] {
        guard !q.isEmpty else { return items }
        let lq = q.lowercased()
        return items.compactMap { item -> PaletteItem? in
            guard let s = CompletionController.fuzzy(lq, item.title.lowercased()) else { return nil }
            var copy = item; copy.score = s; return copy
        }.sorted { $0.score > $1.score }
    }

    private func fileResults(_ q: String, limit: Int) -> [PaletteItem] {
        let ws = workspace
        var paths: [(String, Int)]
        if q.isEmpty {
            let recent = ws.recentFileURLs.map { ws.relative($0) }
            paths = recent.prefix(limit).map { ($0, 0) }
        } else {
            let lq = q.lowercased()
            let lineSuffix = q.split(separator: ":").dropFirst().first.flatMap { Int($0) }
            let fq = lineSuffix != nil ? String(lq.split(separator: ":").first ?? "") : lq
            var scored: [(String, Int)] = []
            for p in ws.fileIndex {
                let name = (p as NSString).lastPathComponent.lowercased()
                if let s = CompletionController.fuzzy(fq, name) { scored.append((p, s + 2000)) }
                else if fq.contains("/"), let s = CompletionController.fuzzy(fq, p.lowercased()) { scored.append((p, s)) }
                if scored.count > 4000 { break }
            }
            scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.count < $1.0.count }
            paths = Array(scored.prefix(limit))
            if let line = lineSuffix {
                return paths.map { p, _ in
                    let url = ws.root.appendingPathComponent(p)
                    return PaletteItem(title: "\(url.lastPathComponent):\(line)", subtitle: (p as NSString).deletingLastPathComponent,
                                       icon: FileIcon.symbol(url), iconColor: FileIcon.color(url)) {
                        ws.pushNavigation()
                        if let doc = ws.open(url) { let off = doc.lineIndex.offset(line: line - 1, character: 0); DispatchQueue.main.async { doc.editor.select(NSRange(location: off, length: 0)) } }
                    }
                }
            }
        }
        return paths.map { p, _ in
            let url = ws.root.appendingPathComponent(p)
            return PaletteItem(title: url.lastPathComponent, subtitle: (p as NSString).deletingLastPathComponent,
                               icon: FileIcon.symbol(url), iconColor: FileIcon.color(url)) { ws.pushNavigation(); ws.open(url) }
        }
    }

    /// Run configurations and project scripts (package.json, Makefile, Cargo, …) — the task runner.
    private func taskItems() -> [PaletteItem] {
        let r = workspace.runner
        return r.configs.map { c in
            PaletteItem(title: c.name, subtitle: c.command.isEmpty ? "Task" : c.command, icon: "play.fill", iconColor: .green) { [weak r] in r?.select(c.name); r?.run(c) }
        }
    }

    private var textResults: [PaletteItem] = []
    private var textTask: Task<Void, Never>?
    /// Text in files (fixed string, case-insensitive), first 60 hits.
    private func searchText(_ q: String) {
        textTask?.cancel()
        guard q.count >= 2 else { textResults = []; results = []; return }
        let root = workspace.root, ws = workspace
        textTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let r = await Task.detached { Shell.run("grep", ["-rniIF", "--exclude-dir=.git", "--exclude-dir=node_modules", "--exclude-dir=.build", "--exclude-dir=build", "--exclude-dir=dist", "-m", "5", "--", q, "."], cwd: root) }.value
            guard !Task.isCancelled, mode == .text else { return }
            textResults = r.out.split(separator: "\n").prefix(60).compactMap { line -> PaletteItem? in
                let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, let n = Int(parts[1]) else { return nil }
                let path = String(parts[0].dropFirst(parts[0].hasPrefix("./") ? 2 : 0))
                let url = root.appendingPathComponent(path)
                return PaletteItem(title: parts[2].trimmingCharacters(in: .whitespaces), subtitle: "\(path):\(n)", icon: FileIcon.symbol(url), iconColor: FileIcon.color(url)) {
                    ws.openUsage(UsageItem(url: url, line: n - 1, column: 0, length: 0, preview: ""))
                }
            }
            results = textResults
            selected = 0
        }
    }

    private func actionResults(_ q: String) -> [PaletteItem] {
        let items = actions.map { a in PaletteItem(title: a.title, subtitle: "Action", icon: a.icon, shortcut: a.shortcut, action: a.run) }
        return filter(items, q, keepOrder: true)
    }

    private func searchSymbols(_ q: String) {
        symbolTask?.cancel()
        guard q.count >= 2 else { symbolResults = []; return }
        symbolTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let found = await workspace.lsp.workspaceSymbols(q)
            guard !Task.isCancelled else { return }
            let ws = workspace
            symbolResults = found.prefix(60).map { s in
                PaletteItem(title: s.name, subtitle: [s.detail, ws.relative(s.url)].filter { !$0.isEmpty }.joined(separator: " — "),
                            icon: SymbolKind.icon(s.kind), iconColor: .purple) { ws.pushNavigation(); ws.open(s.url, range: s.range) }
            }
            if mode == .symbols { results = symbolResults }
            else if mode == .all { results = fileResults(q, limit: 30) + actionResults(q).prefix(8) + symbolResults.prefix(15) }
        }
    }
}

enum FileIcon {
    static func symbol(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "md", "markdown", "txt": return "doc.text"
        case "json", "yaml", "yml", "toml", "plist", "xml": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "icns", "heic": return "photo"
        case "html", "htm", "vue", "svelte": return "chevron.left.forwardslash.chevron.right"
        case "css", "scss", "less": return "paintbrush"
        case "sh", "zsh", "bash", "fish": return "terminal"
        case "lock": return "lock"
        case "sql": return "cylinder"
        default:
            if url.lastPathComponent.hasPrefix(".") { return "gearshape" }
            return "doc.plaintext"
        }
    }

    static func color(_ url: URL) -> Color {
        switch url.pathExtension.lowercased() {
        case "swift": return .orange
        case "js", "mjs", "cjs", "jsx": return .yellow
        case "ts", "tsx", "mts": return .blue
        case "py", "pyi": return Color(red: 0.25, green: 0.5, blue: 0.85)
        case "rs": return Color(red: 0.85, green: 0.45, blue: 0.3)
        case "go": return .cyan
        case "java", "kt", "kts": return .purple
        case "c", "h", "cpp", "hpp", "cc", "m", "mm": return .indigo
        case "rb": return .red
        case "html", "htm": return .orange
        case "css", "scss", "less": return .pink
        case "json", "yaml", "yml", "toml": return .green
        case "md": return .teal
        default: return .secondary
        }
    }
}
