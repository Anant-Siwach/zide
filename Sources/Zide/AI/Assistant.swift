import AppKit
import SwiftUI

// MARK: - The AI assistant: a chat beside the editor that can read and search the project and propose edits.
// Every edit is shown as a reviewable change (diff, Apply, Reject) — nothing is written without you.

/// A shell command the agent wants to run; it waits for Run or Skip.
struct CommandRequest: Identifiable {
    let id = UUID()
    let command: String
    let why: String
    var state: State = .waiting
    var output = ""
    var exitCode: Int32?
    enum State { case waiting, running, done, skipped }
}

struct PendingEdit: Identifiable {
    let id = UUID()
    let url: URL
    let old: String            // text being replaced ("" = new file)
    let new: String
    var state: State = .proposed
    enum State { case proposed, applied, rejected, reverted, failed(String) }
    var added: Int { new.isEmpty ? 0 : new.components(separatedBy: "\n").count }
    var removed: Int { old.isEmpty ? 0 : old.components(separatedBy: "\n").count }
}

@MainActor
final class AssistantModel: ObservableObject {
    struct Turn: Identifiable { let id = UUID(); let role: Role; var text: String; var edits: [UUID] = []; var commands: [UUID] = []
        enum Role { case user, assistant, note } }

    unowned let workspace: Workspace
    @Published var turns: [Turn] = []
    @Published var edits: [UUID: PendingEdit] = [:]
    @Published var input = ""
    /// Agent mode: edits apply (and save) straight away, and the AI may ask to run commands — each needs your OK.
    @Published var agentMode = UserDefaults.standard.bool(forKey: "aiAgentMode") { didSet { UserDefaults.standard.set(agentMode, forKey: "aiAgentMode") } }
    @Published var commands: [UUID: CommandRequest] = [:]
    @Published var busy = false
    @Published var status = ""
    private var history: [AIMessage] = []
    private var noTools = false
    private var task: Task<Void, Never>?

    init(workspace: Workspace) { self.workspace = workspace }

    // MARK: Tools

    static let tools: [AITool] = [
        AITool(name: "read_file", description: "Read a file of the project (with line numbers). Optionally a line range.",
               properties: ["path": ["type": "string", "description": "path relative to the project root"], "start_line": ["type": "integer"], "end_line": ["type": "integer"]], required: ["path"]),
        AITool(name: "list_files", description: "List project files whose path contains the given text (empty = all, first 400).",
               properties: ["contains": ["type": "string"]], required: []),
        AITool(name: "search", description: "Search the project's text for a string (case-insensitive). Returns file:line: text.",
               properties: ["query": ["type": "string"]], required: ["query"]),
        AITool(name: "edit_file", description: "Propose a change: replace old_string (must appear exactly once in the file) with new_string. To create a new file, give an empty old_string. The user reviews and applies it.",
               properties: ["path": ["type": "string"], "old_string": ["type": "string"], "new_string": ["type": "string"]], required: ["path", "old_string", "new_string"]),
        AITool(name: "get_problems", description: "Errors and warnings reported by the language servers, by file.", properties: [:], required: []),
    ]
    static let agentTools: [AITool] = tools + [
        AITool(name: "run_command", description: "Run a shell command in the project folder (build, tests, git status, installing a package…). The user approves each command first; you get the exit code and output. Don't run long-lived servers.",
               properties: ["command": ["type": "string"], "why": ["type": "string", "description": "one short sentence shown to the user"]], required: ["command", "why"]),
    ]
    private var waitingForUser: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func url(_ path: String) -> URL? {
        let p = path.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return nil }
        let u = p.hasPrefix("/") ? URL(fileURLWithPath: p) : workspace.root.appendingPathComponent(p)
        let std = u.standardizedFileURL
        // Only files inside the project.
        guard std.path.hasPrefix(workspace.root.standardizedFileURL.path) else { return nil }
        return std
    }

    /// Current text: the open buffer (with unsaved edits) or the file on disk.
    func content(_ url: URL) -> String? {
        if let d = workspace.documents.first(where: { $0.url.standardizedFileURL == url }) { return d.text }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func run(_ name: String, _ args: [String: Any]) async -> String {
        switch name {
        case "read_file":
            guard let p = args["path"] as? String, let u = url(p) else { return "Give a path inside the project." }
            guard let text = content(u) else { return "No such file: \(p)" }
            let lines = text.components(separatedBy: "\n")
            let a = max(1, (args["start_line"] as? Int) ?? 1), b = min(lines.count, (args["end_line"] as? Int) ?? lines.count)
            guard a <= b else { return "Empty range (the file has \(lines.count) lines)." }
            var out = (a...b).map { "\($0)\t\(lines[$0 - 1])" }.joined(separator: "\n")
            if out.count > 60_000 { out = String(out.prefix(60_000)) + "\n… (cut; read a smaller line range)" }
            status = "Reading \(p)…"
            return out
        case "list_files":
            let q = (args["contains"] as? String ?? "").lowercased()
            let files = workspace.fileIndex.filter { q.isEmpty || $0.lowercased().contains(q) }
            return files.isEmpty ? "No matching files." : files.prefix(400).joined(separator: "\n") + (files.count > 400 ? "\n… \(files.count - 400) more" : "")
        case "search":
            guard let q = args["query"] as? String, !q.isEmpty else { return "Give a query." }
            status = "Searching for “\(q)”…"
            let root = workspace.root
            let r = await Task.detached { Shell.run("grep", ["-rniI", "--exclude-dir=.git", "--exclude-dir=node_modules", "--exclude-dir=.build", "--exclude-dir=build", "--exclude-dir=dist", "-m", "20", "--", q, "."], cwd: root) }.value
            let lines = r.out.split(separator: "\n").prefix(200).map { String($0.dropFirst($0.hasPrefix("./") ? 2 : 0)).prefix(240) }
            return lines.isEmpty ? "No matches." : lines.joined(separator: "\n")
        case "edit_file":
            guard let p = args["path"] as? String, let u = url(p) else { return "Give a path inside the project." }
            let old = args["old_string"] as? String ?? "", new = args["new_string"] as? String ?? ""
            if old.isEmpty {
                if FileManager.default.fileExists(atPath: u.path) && !(content(u) ?? "").isEmpty { return "\(p) already exists — give old_string to change part of it." }
            } else {
                guard let text = content(u) else { return "No such file: \(p)" }
                let n = text.components(separatedBy: old).count - 1
                if n == 0 { return "old_string was not found in \(p). Read the file again and copy the text exactly." }
                if n > 1 { return "old_string appears \(n) times in \(p); include more surrounding lines so it is unique." }
            }
            let e = PendingEdit(url: u, old: old, new: new)
            edits[e.id] = e
            if let i = turns.indices.last(where: { turns[$0].role != .user }) , turns[i].role == .assistant { turns[i].edits.append(e.id) }
            else { turns.append(Turn(role: .assistant, text: "", edits: [e.id])) }
            if agentMode {
                apply(e.id, save: true)
                if case .failed(let m) = edits[e.id]?.state { return "The edit failed: \(m)" }
                return "Applied and saved the change to \(p)."
            }
            return "Proposed the change to \(p). The user will review it (it is not applied yet)."
        case "run_command":
            guard agentMode else { return "Commands are only available in agent mode." }
            let cmd = (args["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cmd.isEmpty else { return "Give a command." }
            var req = CommandRequest(command: cmd, why: args["why"] as? String ?? "")
            commands[req.id] = req
            turns.append(Turn(role: .note, text: "", commands: [req.id]))
            status = "Waiting for you to approve a command…"
            let ok = await withCheckedContinuation { c in waitingForUser[req.id] = c }
            guard ok, !Task.isCancelled else { commands[req.id]?.state = .skipped; return "The user skipped this command. Don't run it again; continue another way or explain what they should run." }
            commands[req.id]?.state = .running
            status = "Running \(cmd.prefix(60))…"
            let r = await Self.execute(cmd, workspace: workspace)
            req = commands[req.id] ?? req
            commands[req.id]?.state = .done; commands[req.id]?.output = r.output; commands[req.id]?.exitCode = r.code
            workspace.git.refresh()
            for d in workspace.documents where !d.isDirty { d.reloadIfChangedOnDisk() }
            return "Exit code \(r.code).\n" + String(r.output.suffix(8000))
        case "get_problems":
            let all = workspace.problems.flatMap { u, ds in ds.map { "\(workspace.relative(u)):\($0.line): \($0.severity == .error ? "error" : "warning"): \($0.message)" } }
            return all.isEmpty ? "No problems reported." : all.prefix(150).joined(separator: "\n")
        default: return "Unknown tool \(name)."
        }
    }

    // MARK: Asking

    var system: String {
        let ws = workspace
        var s = """
        You are the coding assistant inside Zide, a code editor, working on the project "\(ws.name)" (\(ws.fileIndex.count) files). \
        Use the tools to read and search the code before answering; never guess file contents. To change code, call edit_file \
        with an exact old_string copied from read_file output (without the line-number prefix) — the user reviews each change. \
        Keep answers short and concrete; use Markdown code blocks for code.
        """
        if agentMode {
            s += """

            AGENT MODE: work through the task step by step until it is done. Your edits are applied and saved immediately. \
            You can run shell commands with run_command (the user approves each one) — use them to build, run tests and check \
            your work, then fix what fails. Don't start servers or interactive programs. Finish with a short summary of what you \
            changed and how you verified it.
            """
        }
        if let d = ws.active, !d.isBinary {
            s += "\n\nThe user is looking at \(ws.relative(d.url)) (\(d.language.name)), line \(d.cursorLine)."
            if let sel = selection(), !sel.isEmpty { s += " Selected text:\n```\n\(sel.prefix(6000))\n```" }
        }
        return s
    }

    func selection() -> String? {
        guard let d = workspace.active else { return nil }
        let tv = d.editor.textView
        let r = tv.selectedRange()
        guard r.length > 0, NSMaxRange(r) <= d.storage.length else { return nil }
        return (d.storage.string as NSString).substring(with: r)
    }

    func send() { let q = input.trimmingCharacters(in: .whitespacesAndNewlines); input = ""; ask(q) }

    func ask(_ question: String) {
        guard !question.isEmpty, !busy else { return }
        guard AIConfig.isConfigured else { AISettingsView.show(); return }
        if agentMode && noTools { turns.append(Turn(role: .note, text: "Agent mode needs a model with tool calling (Claude, OpenAI, OpenRouter, or a tool-capable Ollama model).")) }
        turns.append(Turn(role: .user, text: question))
        busy = true; status = "Thinking…"
        let sys = system
        task = Task {
            do {
                var reply: String
                if !noTools {
                    do {
                        reply = try await AIClient.runWithTools(system: sys, history: Array(history.suffix(8)), user: question, tools: agentMode ? Self.agentTools : Self.tools, maxSteps: agentMode ? 40 : 16) { [weak self] name, args in
                            await self?.run(name, args) ?? ""
                        }
                    } catch is AIClient.ToolsUnsupported {
                        noTools = true
                        reply = try await plain(sys, question)
                    }
                } else { reply = try await plain(sys, question) }
                history.append(AIMessage(role: "user", text: question))
                history.append(AIMessage(role: "assistant", text: reply))
                if let i = turns.indices.last, turns[i].role == .assistant, turns[i].text.isEmpty { turns[i].text = reply }
                else { turns.append(Turn(role: .assistant, text: reply)) }
            } catch is CancellationError {
                turns.append(Turn(role: .note, text: "Stopped."))
            } catch {
                turns.append(Turn(role: .note, text: "⚠︎ \(error.localizedDescription)"))
            }
            busy = false; status = ""
        }
    }

    /// For models without tools: the open file goes in the question.
    private func plain(_ sys: String, _ q: String) async throws -> String {
        var context = ""
        if let d = workspace.active, !d.isBinary { context = "\n\nCurrent file \(workspace.relative(d.url)):\n```\n\(d.text.prefix(20_000))\n```" }
        return try await AIClient.chat(system: sys + "\n(This model can't use tools: answer from the file below; give changed code in code blocks.)", messages: history.suffix(6) + [AIMessage(role: "user", text: q + context)])
    }

    func approve(_ id: UUID) { waitingForUser.removeValue(forKey: id)?.resume(returning: true) }
    func skip(_ id: UUID) { waitingForUser.removeValue(forKey: id)?.resume(returning: false) }

    /// Runs in the project folder through a login shell (your PATH), or on the server for a remote folder. 5-minute limit.
    nonisolated static func execute(_ cmd: String, workspace ws: Workspace) async -> (code: Int32, output: String) {
        let (root, remote) = await MainActor.run { (ws.root, ws.remote?.spec) }
        let r: (Int32, String) = await Task.detached {
            let p = Process()
            if let s = remote {
                p.executableURL = URL(fileURLWithPath: Remote.ssh)
                p.arguments = Remote.sshOptions + [s.host, "cd \(Remote.q(s.path)) && \(cmd)"]
            } else {
                p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
                p.arguments = ["-l", "-c", cmd]
                p.currentDirectoryURL = root
            }
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return (127, "Couldn't start the command.") }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: killer)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit(); killer.cancel()
            let out = String(decoding: data, as: UTF8.self).replacingOccurrences(of: #"\u{1B}\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
            return (p.terminationStatus, out)
        }.value
        if remote != nil { await MainActor.run { ws.remote?.pull() } }
        return r
    }

    func stop() {
        task?.cancel(); busy = false; status = ""
        for id in Array(waitingForUser.keys) { skip(id) }
    }
    func clear() { turns = []; history = []; edits = [:] }

    // MARK: Edits

    func apply(_ id: UUID, save: Bool = false) {
        guard var e = edits[id] else { return }
        defer { if save, case .applied = edits[id]?.state, let d = workspace.documents.first(where: { $0.url.standardizedFileURL == e.url }) { workspace.save(d) } }
        let fm = FileManager.default
        if e.old.isEmpty && !fm.fileExists(atPath: e.url.path) {
            try? fm.createDirectory(at: e.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: e.url.path, contents: Data(e.new.utf8))
            workspace.rebuildIndex()
            _ = workspace.open(e.url)
            e.state = .applied
        } else if let d = workspace.open(e.url, focus: true) {
            let text = d.storage.string as NSString
            let r = e.old.isEmpty ? NSRange(location: 0, length: text.length) : text.range(of: e.old)
            if r.location == NSNotFound { e.state = .failed("The text changed since the AI read it.") }
            else {
                d.editor.replace([(r, e.new)])           // undoable with ⌘Z, saved with ⌘S
                e.state = .applied
            }
        }
        edits[id] = e
    }
    func reject(_ id: UUID) { edits[id]?.state = .rejected }

    /// Puts back what an applied edit replaced (agent mode).
    func revert(_ id: UUID) {
        guard let e = edits[id], case .applied = e.state, let d = workspace.open(e.url, focus: true) else { return }
        let ns = d.storage.string as NSString
        if e.old.isEmpty && !e.new.isEmpty && ns.length == (e.new as NSString).length {
            try? FileManager.default.trashItem(at: e.url, resultingItemURL: nil)
            workspace.closeDocument(d, force: true)
        } else {
            let r = ns.range(of: e.new)
            guard r.location != NSNotFound else { edits[id]?.state = .failed("The code changed since; undo by hand."); return }
            d.editor.replace([(r, e.old)])
            workspace.save(d)
        }
        edits[id]?.state = .reverted
    }
    func applyAll() { for (id, e) in edits where { if case .proposed = e.state { return true }; return false }() { apply(id) } }

    func diff(_ id: UUID) {
        guard let e = edits[id] else { return }
        let before = content(e.url) ?? ""
        let after = e.old.isEmpty ? e.new : before.replacingOccurrences(of: e.old, with: e.new)
        Compare.show(workspace, left: e.url, rightText: after, right: nil, title: "AI change: \(workspace.relative(e.url))")
    }

    // MARK: Shortcuts used around the editor

    func explain(_ d: Diagnostic, in url: URL) {
        workspace.assistantVisible = true
        ask("Explain this \(d.severity == .error ? "error" : "warning") in \(workspace.relative(url)) line \(d.line) and how to fix it: \(d.message)")
    }
    func fix(_ d: Diagnostic, in url: URL) {
        workspace.assistantVisible = true
        ask("Fix this \(d.severity == .error ? "error" : "warning") in \(workspace.relative(url)) line \(d.line): \(d.message). Read the code around it, then propose the fix with edit_file.")
    }
    func explainSelection() {
        workspace.assistantVisible = true
        ask(selection().map { _ in "Explain the selected code." } ?? "Explain the code around the cursor.")
    }

    /// A commit message from the current changes.
    func commitMessage() {
        guard AIConfig.isConfigured else { AISettingsView.show(); return }
        let root = workspace.root, git = workspace.git
        git.message = "✨ Writing a commit message…"
        Task {
            let (stat, diff) = await Task.detached { () -> (String, String) in
                var d = Shell.run("git", ["diff", "--cached", "--no-color"], cwd: root).out
                if d.isEmpty { d = Shell.run("git", ["diff", "--no-color"], cwd: root).out }
                return (Shell.run("git", ["status", "--short"], cwd: root).out, d)
            }.value
            do {
                let m = try await AIClient.chat(system: "You write git commit messages: a short imperative summary line (max 60 characters), a blank line, then 1-4 bullet points if useful. No quotes, no code fences.",
                                                messages: [AIMessage(role: "user", text: "Files:\n\(stat)\n\nDiff:\n\(String(diff.prefix(14_000)))")], maxTokens: 400)
                git.message = m.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "```", with: "")
            } catch { git.message = ""; workspace.flash("AI: \(error.localizedDescription)") }
        }
    }
}

// MARK: - Panel

struct AssistantPanel: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var model: AssistantModel
    @ObservedObject var theme = ThemeObserver.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Assistant", systemImage: "sparkles").font(.system(size: 12, weight: .semibold))
                Toggle("Agent", isOn: $model.agentMode).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
                    .help("Agent mode: the AI applies its edits and can run commands (each needs your OK) until the job is done")
                Spacer()
                if model.edits.values.contains(where: { if case .proposed = $0.state { return true }; return false }) {
                    Button("Apply All") { model.applyAll() }.controlSize(.small)
                }
                Menu {
                    Button("Clear Chat") { model.clear() }
                    Button("AI Settings…") { AISettingsView.show() }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                Button { ws.assistantVisible = false } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            Divider()
            if !AIConfig.isConfigured {
                VStack(spacing: 10) {
                    Image(systemName: "sparkles").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("Connect an AI: Claude, OpenAI, OpenRouter, Ollama on this Mac, or Apple Intelligence (free, on-device).").font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Set Up AI…") { AISettingsView.show() }.buttonStyle(.borderedProminent)
                }.padding(20).frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if model.turns.isEmpty {
                                Text("Ask about your code, or ask for a change. The assistant reads and searches the project; every change it proposes waits for your OK.")
                                    .font(.callout).foregroundStyle(.secondary)
                                ForEach(["Explain the file I'm looking at", "Find where errors are handled", "Write tests for the selected code"], id: \.self) { s in
                                    Button(s) { model.ask(s) }.buttonStyle(.link).font(.callout)
                                }
                            }
                            ForEach(model.turns) { t in turn(t).id(t.id) }
                            if model.busy { HStack { ProgressView().controlSize(.small); Text(model.status).font(.caption).foregroundStyle(.secondary); Spacer(); Button("Stop") { model.stop() }.controlSize(.small) } }
                        }.padding(10)
                    }
                    .onChange(of: model.turns.count) { _, _ in if let l = model.turns.last { withAnimation { proxy.scrollTo(l.id, anchor: .bottom) } } }
                }
                Divider()
                HStack(alignment: .bottom) {
                    TextField("Ask or describe a change… (↩ to send)", text: $model.input, axis: .vertical)
                        .textFieldStyle(.plain).lineLimit(1...6).onSubmit { model.send() }
                    Button { model.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 18)) }
                        .buttonStyle(.borderless).disabled(model.busy || model.input.isEmpty)
                }
                .padding(10)
                Text(AIConfig.current.model).font(.system(size: 10)).foregroundStyle(.tertiary).padding(.bottom, 5)
            }
        }
        .background(theme.palette.chrome.swiftUI)
    }

    @ViewBuilder private func turn(_ t: AssistantModel.Turn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !t.text.isEmpty {
                Text(LocalizedStringKey(t.text)).font(.system(size: 12.5)).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(t.role == .user ? theme.palette.accent.swiftUI.opacity(0.15) : t.role == .note ? Color.orange.opacity(0.12) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(t.edits, id: \.self) { id in if let e = model.edits[id] { editCard(e) } }
            ForEach(t.commands, id: \.self) { id in if let c = model.commands[id] { commandCard(c) } }
        }
    }

    private func commandCard(_ c: CommandRequest) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if !c.why.isEmpty { Text(c.why).font(.caption).foregroundStyle(.secondary) }
            Text("$ " + c.command).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            switch c.state {
            case .waiting:
                HStack {
                    Button("Run") { model.approve(c.id) }.buttonStyle(.borderedProminent).controlSize(.small).keyboardShortcut(.return, modifiers: .command)
                    Button("Skip") { model.skip(c.id) }.controlSize(.small)
                    Text("⌘↩ runs it").font(.caption2).foregroundStyle(.tertiary)
                }
            case .running: HStack { ProgressView().controlSize(.mini); Text("Running…").font(.caption) }
            case .skipped: Label("Skipped", systemImage: "forward").font(.caption).foregroundStyle(.secondary)
            case .done:
                DisclosureGroup {
                    ScrollView { Text(c.output.suffix(6000)).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160)
                } label: {
                    Label("Exit \(c.exitCode ?? -1)", systemImage: c.exitCode == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.caption).foregroundStyle(c.exitCode == 0 ? Color.green : Color.red)
                }
            }
        }
        .padding(8)
        .background(Color.orange.opacity(c.state == .waiting ? 0.10 : 0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(c.state == .waiting ? 0.5 : 0.15)))
    }

    private func editCard(_ e: PendingEdit) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: e.old.isEmpty ? "doc.badge.plus" : "pencil").foregroundStyle(.secondary)
                Text(ws.relative(e.url)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text("+\(e.added) −\(e.removed)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
            }
            Text(e.new.prefix(400) + (e.new.count > 400 ? "…" : "")).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(6)
            HStack {
                switch e.state {
                case .proposed:
                    Button("Apply") { model.apply(e.id) }.buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Diff") { model.diff(e.id) }.controlSize(.small)
                    Button("Reject") { model.reject(e.id) }.controlSize(.small)
                case .applied:
                    Label(model.agentMode ? "Applied and saved" : "Applied — ⌘Z to undo, ⌘S to save", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    Spacer()
                    Button("Diff") { model.diff(e.id) }.controlSize(.mini)
                    Button("Revert") { model.revert(e.id) }.controlSize(.mini)
                case .reverted: Label("Reverted", systemImage: "arrow.uturn.backward.circle").font(.caption).foregroundStyle(.secondary)
                case .rejected: Label("Rejected", systemImage: "xmark.circle").font(.caption).foregroundStyle(.secondary)
                case .failed(let m): Label(m, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
    }
}
