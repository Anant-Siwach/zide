import AppKit

struct GitChange: Identifiable, Hashable {
    let path: String
    let index: Character     // staged status
    let work: Character      // unstaged status
    var id: String { path }
    var isUntracked: Bool { index == "?" }
    var isStaged: Bool { index != " " && index != "?" }
    var label: String {
        if isUntracked { return "U" }
        let c = isStaged ? index : work
        return String(c)
    }
}

@MainActor
final class GitModel: ObservableObject {
    unowned let workspace: Workspace
    @Published private(set) var isRepo = false
    @Published private(set) var branch = ""
    @Published private(set) var ahead = 0
    @Published private(set) var behind = 0
    @Published private(set) var changes: [GitChange] = []
    @Published private(set) var branches: [String] = []
    @Published private(set) var log: [(hash: String, subject: String, author: String, date: String)] = []
    @Published var message = ""
    @Published var amend = false
    @Published var busy: String?
    @Published var selected: Set<String> = []
    @Published var diffText = ""
    @Published var diffPath: String?
    /// Changed lines vs HEAD per file (1-based line → kind), shown as gutter bars.
    @Published private(set) var lineChanges: [URL: [Int: LineChange]] = [:]
    @Published private(set) var blame: String = ""
    private var blameTask: Task<Void, Never>?
    enum LineChange { case added, modified, deleted }
    private var refreshing = false
    private var refreshAgain = false

    init(workspace: Workspace) { self.workspace = workspace }

    var root: URL { workspace.root }

    /// Status by absolute path, for colouring the project tree.
    var statusByPath: [String: Character] {
        var m: [String: Character] = [:]
        for c in changes {
            let ch: Character = c.isUntracked ? "?" : (c.work != " " ? c.work : c.index)
            m[root.path + "/" + c.path] = ch
        }
        return m
    }

    func refresh() {
        if refreshing { refreshAgain = true; return }
        refreshing = true
        let root = self.root
        Task.detached(priority: .utility) {
            let st = Shell.run("git", ["status", "--porcelain=v1", "-b", "--untracked-files=all"], cwd: root)
            let br = Shell.run("git", ["branch", "--format=%(refname:short)"], cwd: root)
            await MainActor.run {
                self.refreshing = false
                self.isRepo = st.ok
                if st.ok { self.parse(st.out) } else { self.changes = []; self.branch = "" }
                self.branches = br.out.split(separator: "\n").map(String.init)
                self.selected = self.selected.intersection(Set(self.changes.map(\.path)))
                if self.selected.isEmpty { self.selected = Set(self.changes.map(\.path)) }
                if self.refreshAgain { self.refreshAgain = false; self.refresh() }
            }
        }
    }

    private func parse(_ out: String) {
        var list: [GitChange] = []
        for line in out.split(separator: "\n") {
            if line.hasPrefix("## ") {
                let info = line.dropFirst(3)
                branch = String(info.split(separator: ".").first ?? Substring(info)).replacingOccurrences(of: "No commits yet on ", with: "")
                if let r = info.range(of: "ahead ") { ahead = Int(info[r.upperBound...].prefix { $0.isNumber }) ?? 0 } else { ahead = 0 }
                if let r = info.range(of: "behind ") { behind = Int(info[r.upperBound...].prefix { $0.isNumber }) ?? 0 } else { behind = 0 }
                continue
            }
            guard line.count > 3 else { continue }
            let chars = Array(line)
            var path = String(line.dropFirst(3))
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            if path.hasPrefix("\"") { path = String(path.dropFirst().dropLast()) }
            list.append(GitChange(path: path, index: chars[0], work: chars[1]))
        }
        changes = list.sorted { $0.path < $1.path }
    }

    func loadLog() {
        let root = self.root
        Task.detached {
            let r = Shell.run("git", ["log", "-100", "--pretty=format:%h\u{1f}%s\u{1f}%an\u{1f}%cr"], cwd: root)
            let entries = r.out.split(separator: "\n").map { l -> (String, String, String, String) in
                let p = l.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                return (p[safe: 0] ?? "", p[safe: 1] ?? "", p[safe: 2] ?? "", p[safe: 3] ?? "")
            }
            await MainActor.run { self.log = entries.map { (hash: $0.0, subject: $0.1, author: $0.2, date: $0.3) } }
        }
    }

    func showDiff(_ change: GitChange) {
        diffPath = change.path
        let root = self.root
        Task.detached {
            var r: Shell.Result
            if change.isUntracked {
                r = Shell.run("git", ["diff", "--no-index", "--", "/dev/null", change.path], cwd: root)
            } else {
                r = Shell.run("git", ["diff", "HEAD", "--", change.path], cwd: root)
                if r.out.isEmpty { r = Shell.run("git", ["diff", "--cached", "--", change.path], cwd: root) }
            }
            await MainActor.run { self.diffText = r.out.isEmpty ? "(no textual changes)" : r.out }
        }
    }

    private func git(_ args: [String], label: String, then: ((Shell.Result) -> Void)? = nil) {
        busy = label
        let root = self.root
        Task.detached {
            let r = Shell.run("git", args, cwd: root)
            await MainActor.run {
                self.busy = nil
                if !r.ok {
                    let a = NSAlert()
                    a.messageText = "git \(args.first ?? "") failed"
                    a.informativeText = String((r.err.isEmpty ? r.out : r.err).suffix(1500))
                    a.runModal()
                }
                then?(r)
                self.refresh()
            }
        }
    }

    func commit(andPush: Bool) {
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty || amend else { workspace.flash("Enter a commit message"); return }
        workspace.saveAll()
        let paths = changes.filter { selected.contains($0.path) }.map(\.path)
        guard !paths.isEmpty else { workspace.flash("Select files to commit"); return }
        let root = self.root
        busy = "Committing…"
        Task.detached {
            let add = Shell.run("git", ["add", "-A", "--"] + paths, cwd: root)
            var args = ["commit", "-m", msg.isEmpty ? "amend" : msg]
            if await self.amend { args.append("--amend"); if msg.isEmpty { args = ["commit", "--amend", "--no-edit"] } }
            let c = add.ok ? Shell.run("git", args + ["--"] + paths, cwd: root) : add
            await MainActor.run {
                self.busy = nil
                if c.ok {
                    self.message = ""
                    self.amend = false
                    self.workspace.flash("Committed \(paths.count) file\(paths.count == 1 ? "" : "s")")
                    if andPush { self.push() }
                } else {
                    let a = NSAlert(); a.messageText = "Commit failed"; a.informativeText = String((c.err + c.out).suffix(1500)); a.runModal()
                }
                self.refresh()
            }
        }
    }

    func push() {
        git(["push"], label: "Pushing…") { [weak self] r in if r.ok { self?.workspace.flash("Pushed to \(self?.branch ?? "remote")") } }
    }

    func pull() {
        git(["pull", "--ff-only"], label: "Pulling…") { [weak self] r in if r.ok { self?.workspace.flash("Pulled \(self?.branch ?? "")") } }
    }

    func fetch() { git(["fetch", "--all", "--prune"], label: "Fetching…") }

    func checkout(_ branch: String) {
        workspace.saveAll()
        git(["checkout", branch], label: "Checking out \(branch)…")
    }

    func newBranch() {
        let a = NSAlert()
        a.messageText = "New Branch"
        let field = NSTextField(string: "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: "Create"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        git(["checkout", "-b", name], label: "Creating \(name)…")
    }

    /// Discards local changes to a file (asks first — this can't be undone).
    func rollback(_ change: GitChange) {
        let a = NSAlert()
        a.messageText = "Roll back changes to \(change.path)?"
        a.informativeText = change.isUntracked ? "The new file will be moved to the Trash." : "Your local changes to this file will be lost."
        a.addButton(withTitle: "Roll Back"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if change.isUntracked {
            NSWorkspace.shared.recycle([root.appendingPathComponent(change.path)]) { [weak self] _, _ in DispatchQueue.main.async { self?.refresh() } }
        } else {
            git(["checkout", "HEAD", "--", change.path], label: "Rolling back…")
        }
    }

    func initRepo() { git(["init"], label: "Initialising…") }

    /// Parses `git diff -U0` hunks into per-line markers for the gutter.
    func loadLineChanges(_ doc: EditorDocument) {
        guard isRepo || FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) else { return }
        let url = doc.url, root = self.root
        Task.detached(priority: .utility) {
            let tracked = Shell.run("git", ["ls-files", "--error-unmatch", url.path], cwd: root).ok
            var marks: [Int: LineChange] = [:]
            if tracked {
                let r = Shell.run("git", ["diff", "-U0", "HEAD", "--", url.path], cwd: root)
                for line in r.out.split(separator: "\n") where line.hasPrefix("@@") {
                    // @@ -a,b +c,d @@
                    let parts = line.split(separator: " ")
                    guard parts.count >= 3 else { continue }
                    func parse(_ s: Substring) -> (Int, Int) {
                        let nums = s.dropFirst().split(separator: ",").compactMap { Int($0) }
                        return (nums.first ?? 0, nums.count > 1 ? nums[1] : 1)
                    }
                    let (_, oldCount) = parse(parts[1]), (newStart, newCount) = parse(parts[2])
                    if newCount == 0 { marks[max(1, newStart)] = .deleted; continue }
                    for l in newStart..<(newStart + newCount) { marks[l] = oldCount == 0 ? .added : .modified }
                }
            }
            await MainActor.run {
                self.lineChanges[url] = marks
                for d in self.workspace.documents where d.url == url { d.editors.forEach { $0.ruler?.needsDisplay = true } }
            }
        }
    }

    /// `git blame` for one line, shown in the status bar (debounced by the caller).
    func loadBlame(_ url: URL, line: Int) {
        blameTask?.cancel()
        guard isRepo, Prefs.shared.showBlame else { blame = ""; return }
        let root = self.root
        blameTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            let r = Shell.run("git", ["blame", "-L", "\(line),\(line)", "--porcelain", "--", url.path], cwd: root)
            var author = "", time = 0.0, summary = ""
            for l in r.out.split(separator: "\n") {
                if l.hasPrefix("author ") { author = String(l.dropFirst(7)) }
                if l.hasPrefix("author-time ") { time = Double(l.dropFirst(12)) ?? 0 }
                if l.hasPrefix("summary ") { summary = String(l.dropFirst(8)) }
            }
            let text: String
            if !r.ok || author.isEmpty { text = "" }
            else if author == "Not Committed Yet" { text = "You · uncommitted" }
            else {
                let rel = RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: time), relativeTo: Date())
                text = "\(author), \(rel) · \(summary)"
            }
            if Task.isCancelled { return }
            await MainActor.run { self.blame = text }
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
