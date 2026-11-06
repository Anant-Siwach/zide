import AppKit

struct StackFrame: Identifiable {
    let id: Int
    let name: String
    let url: URL?
    let line: Int        // 1-based
}

struct ConsoleLine: Identifiable {
    let id = UUID()
    let text: String
    let kind: Kind
    enum Kind { case stdout, stderr, info, input, result, error }
}

/// A variable (or scope) in the Variables tree; children load on demand.
@MainActor
final class VarNode: ObservableObject, Identifiable {
    let id = UUID()
    let name: String
    let value: String
    let type: String
    let reference: Int
    @Published var children: [VarNode]?
    @Published var expanded = false

    init(name: String, value: String, type: String, reference: Int) {
        self.name = name; self.value = value; self.type = type; self.reference = reference
    }

    var expandable: Bool { reference > 0 }
}

/// What DebugManager needs from a debugger protocol implementation (DAP or Node's inspector).
@MainActor
protocol DebugBackend: AnyObject {
    func start()
    func setBreakpoints(path: String, lines: [(line: Int, condition: String)])
    func resume(); func stepOver(); func stepInto(); func stepOut(); func pause()
    func stop()
    func stackTrace(_ done: @escaping ([StackFrame]) -> Void)
    func scopes(frame: StackFrame, _ done: @escaping ([VarNode]) -> Void)
    func variables(reference: Int, _ done: @escaping ([VarNode]) -> Void)
    func evaluate(_ expression: String, frame: StackFrame?, _ done: @escaping (String, Bool) -> Void)
}

/// Callbacks a backend uses to report to the manager.
@MainActor
final class DebugEvents {
    var ready: () -> Void = {}                       // configured; send breakpoints now
    var stopped: (String) -> Void = { _ in }         // reason
    var continued: () -> Void = {}
    var output: (String, ConsoleLine.Kind) -> Void = { _, _ in }
    var terminated: () -> Void = {}
}

@MainActor
final class DebugManager: ObservableObject {
    enum State: Equatable { case idle, building, starting, running, stopped, finished }

    unowned let workspace: Workspace
    @Published private(set) var state: State = .idle
    /// path → (1-based line → condition, "" for none)
    @Published private(set) var breakpoints: [String: [Int: String]] = [:]
    @Published private(set) var frames: [StackFrame] = []
    @Published var selectedFrame: Int?
    @Published private(set) var scopes: [VarNode] = []
    @Published private(set) var console: [ConsoleLine] = []
    @Published private(set) var stopReason = ""
    @Published private(set) var targetName = ""
    @Published private(set) var executionPoint: (url: URL, line: Int)?
    private var backend: DebugBackend?
    private var configured = false

    init(workspace: Workspace) {
        self.workspace = workspace
        let raw = UserDefaults.standard.dictionary(forKey: storeKey) ?? [:]
        for (path, value) in raw {
            if let lines = value as? [Int] { breakpoints[path] = Dictionary(uniqueKeysWithValues: lines.map { ($0, "") }) }
            else if let map = value as? [String: String] { breakpoints[path] = Dictionary(uniqueKeysWithValues: map.compactMap { k, v in Int(k).map { ($0, v) } }) }
        }
    }

    private var storeKey: String { "breakpoints:" + workspace.root.path }
    var isActive: Bool { state != .idle && state != .finished }

    // MARK: Breakpoints

    func lines(for url: URL) -> Set<Int> { Set((breakpoints[url.standardizedFileURL.path] ?? [:]).keys) }
    func condition(for url: URL, line: Int) -> String { breakpoints[url.standardizedFileURL.path]?[line] ?? "" }

    func toggleBreakpoint(_ url: URL, line: Int) {
        let path = url.standardizedFileURL.path
        var map = breakpoints[path] ?? [:]
        if map[line] != nil { map[line] = nil } else { map[line] = "" }
        update(path, map)
        repaint(url)
    }

    /// Sets (or clears, with "") the condition; adds the breakpoint if needed.
    func setCondition(_ url: URL, line: Int, condition: String) {
        let path = url.standardizedFileURL.path
        var map = breakpoints[path] ?? [:]
        map[line] = condition.trimmingCharacters(in: .whitespaces)
        update(path, map)
        repaint(url)
    }

    func editCondition(_ url: URL, line: Int) {
        let a = NSAlert()
        a.messageText = "Breakpoint condition"
        a.informativeText = "Stop at line \(line) only when this expression is true (leave empty to always stop)."
        let field = NSTextField(string: condition(for: url, line: line))
        field.placeholderString = "e.g. i == 3"
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: "Done"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        setCondition(url, line: line, condition: field.stringValue)
    }

    private func update(_ path: String, _ map: [Int: String]) {
        breakpoints[path] = map.isEmpty ? nil : map
        persist()
        if configured { sendBreakpoints(path) }
    }

    /// Keeps breakpoints on the same code when lines are inserted or removed above them.
    func shiftBreakpoints(_ url: URL, fromLine: Int, delta: Int, removed: ClosedRange<Int>?) {
        let path = url.standardizedFileURL.path
        guard delta != 0, let map = breakpoints[path] else { return }
        var out: [Int: String] = [:]
        for (l, c) in map {
            if let removed, removed.contains(l), l != removed.lowerBound { continue }
            out[l > fromLine ? max(1, l + delta) : l] = c
        }
        breakpoints[path] = out.isEmpty ? nil : out
        persist()
    }

    func removeAllBreakpoints() {
        let paths = Array(breakpoints.keys)
        breakpoints = [:]
        persist()
        if configured { paths.forEach(sendBreakpoints) }
        workspace.documents.forEach { repaint($0.url) }
    }

    private func persist() {
        UserDefaults.standard.set(breakpoints.mapValues { m in Dictionary(uniqueKeysWithValues: m.map { (String($0.key), $0.value) }) }, forKey: storeKey)
    }

    private func repaint(_ url: URL) {
        for d in workspace.documents where d.url == url.standardizedFileURL { d.editors.forEach { $0.ruler?.needsDisplay = true; $0.textView.needsDisplay = true } }
    }

    private func sendBreakpoints(_ path: String) {
        let lines = (breakpoints[path] ?? [:]).sorted { $0.key < $1.key }.map { (line: $0.key, condition: $0.value) }
        backend?.setBreakpoints(path: Self.realPath(path), lines: lines)
    }

    /// The real on-disk path (resolving /tmp → /private/tmp and other symlinks), which is what debug info records.
    nonisolated static func realPath(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }

    /// Maps a debugger path (/private/tmp/…) to the form open documents use (/tmp/…).
    static func canonical(_ url: URL) -> URL {
        let std = url.standardizedFileURL
        return std.path.hasPrefix("/private/tmp/") ? URL(fileURLWithPath: String(std.path.dropFirst("/private".count))) : std
    }

    // MARK: Launch

    enum Kind { case dap(adapter: String, args: [String]), dapTCP(adapter: String, args: [String], port: Int), node(file: String, typescript: Bool) }

    struct Target {
        var kind: Kind
        var launch: JSON
        var name: String
        var build: String?
        var resolveProgram: (() -> String?)?
    }

    enum TargetResult { case success(Target), failure(String) }

    func start() {
        guard !isActive else { workspace.flash("A debug session is already running"); return }
        workspace.saveAll()
        console = []; frames = []; scopes = []
        executionPoint = nil
        state = .building
        workspace.bottomTab = .debug
        workspace.bottomVisible = true
        let ws = workspace
        let config = ws.runner.selected
        let active = ws.active
        let root = ws.root, url = active?.url, lang = active?.language
        Task.detached { [weak self] in
            let result = Self.makeTarget(root: root, config: config, activeURL: url, language: lang)
            await MainActor.run {
                guard let self else { return }
                switch result {
                case .failure(let msg): self.log(msg, .error); self.state = .finished
                case .success(let t): self.build(t)
                }
            }
        }
    }

    private func build(_ t: Target) {
        targetName = t.name
        guard let cmd = t.build else { launch(t); return }
        log("$ \(cmd)", .info)
        let root = workspace.root
        Task.detached { [weak self] in
            let r = Shell.run(Env.environment["SHELL"] ?? "/bin/zsh", ["-l", "-c", cmd], cwd: root)
            let resolved: String? = r.ok ? t.resolveProgram?() : nil
            await MainActor.run {
                guard let self else { return }
                let out = (r.out + r.err).trimmingCharacters(in: .whitespacesAndNewlines)
                if !out.isEmpty { self.log(String(out.suffix(6000)), r.ok ? .stdout : .stderr) }
                guard r.ok else { self.log("Build failed — not starting the debugger.", .error); self.state = .finished; return }
                var t = t
                if t.resolveProgram != nil {
                    guard let p = resolved else { self.log("Couldn't find the built executable.", .error); self.state = .finished; return }
                    t.launch["program"] = p
                }
                self.launch(t)
            }
        }
    }

    private func launch(_ t: Target) {
        state = .starting
        let events = DebugEvents()
        events.ready = { [weak self] in
            guard let self else { return }
            self.configured = true
            for path in self.breakpoints.keys { self.sendBreakpoints(path) }
            if self.state == .starting { self.state = .running }
        }
        events.stopped = { [weak self] reason in
            self?.stopReason = reason
            self?.state = .stopped
            self?.loadStack()
        }
        events.continued = { [weak self] in
            self?.state = .running
            self?.frames = []; self?.scopes = []
            self?.setExecutionPoint(nil)
        }
        events.output = { [weak self] text, kind in self?.log(text, kind, raw: true) }
        events.terminated = { [weak self] in self?.finished() }

        let root = workspace.root
        switch t.kind {
        case .dap(let adapter, let args):
            backend = DAPBackend(events: events, transport: .stdio(adapter, args), cwd: root, launch: t.launch,
                                 adapterID: args.contains("debugpy.adapter") ? "debugpy" : "lldb-dap")
        case .dapTCP(let adapter, let args, let port):
            backend = DAPBackend(events: events, transport: .tcp(adapter, args, port), cwd: root, launch: t.launch, adapterID: "go")
        case .node(let file, let ts):
            backend = NodeBackend(events: events, file: file, typescript: ts, cwd: root)
        }
        configured = false
        log("Debugging \(t.name)…", .info)
        backend?.start()
    }

    nonisolated private static func makeTarget(root: URL, config: RunConfig, activeURL: URL?, language: Language?) -> TargetResult {
        let fm = FileManager.default
        let lldb: String? = {
            let r = Shell.run("xcrun", ["--find", "lldb-dap"])
            let p = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            return r.ok && !p.isEmpty ? p : Env.which("lldb-dap")
        }()
        func native(_ name: String, program: String?, build: String?, resolve: (() -> String?)? = nil) -> TargetResult {
            guard let lldb else { return .failure("lldb-dap not found — install Xcode or the Command Line Tools.") }
            var launch: JSON = ["name": name, "type": "lldb-dap", "request": "launch", "cwd": root.path, "args": [], "stopOnEntry": false]
            if let program { launch["program"] = program }
            return .success(Target(kind: .dap(adapter: lldb, args: []), launch: launch, name: name, build: build, resolveProgram: resolve))
        }
        let usesFile = config.name == RunConfig.currentFile.name
        let lang = language?.id ?? ""

        if usesFile && lang == "python", let file = activeURL {
            guard let py = Env.which("python3") else { return .failure("python3 not found") }
            guard Shell.run(py, ["-c", "import debugpy"]).ok else { return .failure("Python debugging needs debugpy — run: pip3 install debugpy") }
            return .success(Target(kind: .dap(adapter: py, args: ["-m", "debugpy.adapter"]),
                                   launch: ["type": "python", "request": "launch", "program": realPath(file.path), "cwd": root.path,
                                            "console": "internalConsole", "justMyCode": true, "python": py],
                                   name: file.lastPathComponent, build: nil))
        }
        if usesFile && ["javascript", "typescript", "javascriptreact", "typescriptreact"].contains(lang), let file = activeURL {
            guard Env.which("node") != nil else { return .failure("Node.js not found on your PATH.") }
            return .success(Target(kind: .node(file: realPath(file.path), typescript: lang.hasPrefix("typescript")), launch: [:], name: file.lastPathComponent, build: nil))
        }
        if lang == "go" || (!usesFile && fm.fileExists(atPath: root.appendingPathComponent("go.mod").path)) {
            guard let dlv = Env.which("dlv") else { return .failure("Go debugging needs Delve — run: go install github.com/go-delve/delve/cmd/dlv@latest  (or brew install delve)") }
            let port = Int.random(in: 40000...60000)
            let program = usesFile ? (activeURL.map { realPath($0.path) } ?? root.path) : realPath(root.path)
            return .success(Target(kind: .dapTCP(adapter: dlv, args: ["dap", "--listen", "127.0.0.1:\(port)"], port: port),
                                   launch: ["type": "go", "request": "launch", "mode": "debug", "program": program, "cwd": root.path],
                                   name: (program as NSString).lastPathComponent, build: nil))
        }
        if fm.fileExists(atPath: root.appendingPathComponent("Package.swift").path) && (!usesFile || lang == "swift") {
            let wanted = config.command.hasPrefix("swift run ") ? String(config.command.dropFirst("swift run ".count)) : nil
            return native(wanted ?? root.lastPathComponent, program: nil, build: "swift build" + (wanted.map { " --product \($0)" } ?? "")) {
                let bin = Shell.run("swift", ["build", "--show-bin-path"], cwd: root).out.trimmingCharacters(in: .whitespacesAndNewlines)
                let desc = Shell.run("swift", ["package", "describe", "--type", "json"], cwd: root).out
                var products: [String] = []
                if let data = desc.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: data) as? JSON {
                    for p in (j["products"] as? [JSON]) ?? [] where (p["type"] as? JSON)?["executable"] != nil { if let n = p["name"] as? String { products.append(n) } }
                }
                let name = wanted ?? products.first
                return name.map { bin + "/" + $0 }.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
            }
        }
        if fm.fileExists(atPath: root.appendingPathComponent("Cargo.toml").path) && (!usesFile || lang == "rust") {
            return native(root.lastPathComponent, program: nil, build: "cargo build") {
                let meta = Shell.run("cargo", ["metadata", "--no-deps", "--format-version", "1"], cwd: root).out
                guard let data = meta.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: data) as? JSON else { return nil }
                let targetDir = j["target_directory"] as? String ?? root.appendingPathComponent("target").path
                for pkg in (j["packages"] as? [JSON]) ?? [] {
                    for t in (pkg["targets"] as? [JSON]) ?? [] where ((t["kind"] as? [String]) ?? []).contains("bin") {
                        if let n = t["name"] as? String { return targetDir + "/debug/" + n }
                    }
                }
                return nil
            }
        }
        if let file = activeURL {
            let out = fm.temporaryDirectory.appendingPathComponent("zide-debug-" + file.deletingPathExtension().lastPathComponent).path
            let q = Shell.quote(realPath(file.path))
            switch lang {
            case "c": return native(file.lastPathComponent, program: out, build: "clang -g -O0 \(q) -o \(Shell.quote(out))")
            case "cpp": return native(file.lastPathComponent, program: out, build: "clang++ -std=c++20 -g -O0 \(q) -o \(Shell.quote(out))")
            case "objective-c": return native(file.lastPathComponent, program: out, build: "clang -g -O0 -framework Foundation \(q) -o \(Shell.quote(out))")
            case "swift": return native(file.lastPathComponent, program: out, build: "swiftc -g -Onone \(q) -o \(Shell.quote(out))")
            case "rust": return native(file.lastPathComponent, program: out, build: "rustc -g \(q) -o \(Shell.quote(out))")
            case "zig": return native(file.lastPathComponent, program: out, build: "zig build-exe -femit-bin=\(Shell.quote(out)) \(q)")
            default: break
            }
        }
        return .failure("Zide can debug Swift, C, C++, Objective-C, Rust, Zig, Go, Python, JavaScript and TypeScript. Open a file in one of those languages or pick a Swift / Cargo / Go run configuration.")
    }

    // MARK: Session

    private func finished() {
        guard state != .finished && state != .idle else { return }
        backend?.stop()
        backend = nil
        configured = false
        state = .finished
        frames = []; scopes = []
        setExecutionPoint(nil)
    }

    private func loadStack() {
        backend?.stackTrace { [weak self] frames in
            guard let self else { return }
            self.frames = frames
            let idx = frames.firstIndex { $0.url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false } ?? 0
            self.selectFrame(idx)
        }
    }

    func selectFrame(_ i: Int) {
        guard frames.indices.contains(i) else { return }
        selectedFrame = i
        let f = frames[i]
        if let url = f.url, FileManager.default.fileExists(atPath: url.path) {
            setExecutionPoint((url, f.line))
            if let doc = workspace.open(Self.canonical(url), focus: false) {
                let off = doc.lineIndex.offset(line: f.line - 1, character: 0)
                DispatchQueue.main.async { doc.editor.select(NSRange(location: off, length: 0)) }
            }
        }
        backend?.scopes(frame: f) { [weak self] scopes in
            self?.scopes = scopes
            if let first = scopes.first { self?.toggle(first) }
        }
    }

    func toggle(_ node: VarNode) {
        node.expanded.toggle()
        guard node.expanded, node.children == nil, node.reference > 0 else { return }
        backend?.variables(reference: node.reference) { node.children = $0 }
    }

    private func setExecutionPoint(_ p: (URL, Int)?) {
        let old = executionPoint?.url
        executionPoint = p.map { (url: Self.canonical($0.0), line: $0.1) }
        if let old { repaint(old) }
        if let p { repaint(Self.canonical(p.0)) }
    }

    // MARK: Controls

    func resume() { guard state == .stopped else { return }; backend?.resume(); state = .running; setExecutionPoint(nil) }
    func stepOver() { guard state == .stopped else { return }; backend?.stepOver() }
    func stepInto() { guard state == .stopped else { return }; backend?.stepInto() }
    func stepOut() { guard state == .stopped else { return }; backend?.stepOut() }
    func pause() { guard state == .running else { return }; backend?.pause() }

    func stop() {
        guard backend != nil else { finished(); return }
        backend?.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.finished() }
    }

    func evaluate(_ expr: String) {
        let e = expr.trimmingCharacters(in: .whitespaces)
        guard !e.isEmpty else { return }
        log("› " + e, .input)
        guard let b = backend else { log("No debug session", .error); return }
        let frame = selectedFrame.flatMap { frames.indices.contains($0) ? frames[$0] : nil }
        b.evaluate(e, frame: frame) { [weak self] text, ok in self?.log(text, ok ? .result : .error) }
    }

    func log(_ text: String, _ kind: ConsoleLine.Kind, raw: Bool = false) {
        let t = raw ? text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: CharacterSet(charactersIn: "\r\n")) : text
        guard !t.isEmpty else { return }
        console.append(ConsoleLine(text: t, kind: kind))
        if console.count > 3000 { console.removeFirst(console.count - 3000) }
    }
}
