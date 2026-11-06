import AppKit
import SwiftTerm

/// A terminal tab: an interactive shell or a run configuration's process.
@MainActor
final class TerminalSession: NSObject, Identifiable, ObservableObject, LocalProcessTerminalViewDelegate {
    let id = UUID()
    @Published var title: String
    @Published var running = true
    @Published var exitCode: Int32?
    let view: LocalProcessTerminalView
    let isRun: Bool

    init(title: String, cwd: URL, command: String?, isRun: Bool) {
        self.title = title
        self.isRun = isRun
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        super.init()
        view.processDelegate = self
        applyTheme()
        let env = Env.environment.map { "\($0.key)=\($0.value)" }
        let shell = Env.environment["SHELL"] ?? "/bin/zsh"
        if let command {
            // Run through a login shell so PATH / nvm / pyenv match the user's terminal.
            let script = "\(command)\nstatus=$?\nprintf '\\n\\033[2m[Process finished with exit code %d]\\033[0m\\n' $status\nexit $status"
            view.startProcess(executable: shell, args: ["-l", "-c", script], environment: env, execName: nil, currentDirectory: cwd.path)
        } else {
            view.startProcess(executable: shell, args: ["-l"], environment: env, execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: cwd.path)
        }
    }

    func applyTheme() {
        let p = Theme.current
        view.nativeBackgroundColor = p.background
        view.nativeForegroundColor = p.text
        view.caretColor = p.cursor
        view.selectedTextBackgroundColor = p.selection
        view.font = NSFont.monospacedSystemFont(ofSize: CGFloat(Prefs.shared.terminalFontSize), weight: .regular)
        view.optionAsMetaKey = false
    }

    func send(_ text: String) { view.send(txt: text) }

    func terminate() {
        if running { view.process.terminate() }
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { if !self.isRun, !title.isEmpty { self.title = title } }
    }
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            self.running = false
            self.exitCode = exitCode
        }
    }
}

@MainActor
final class TerminalManager: ObservableObject {
    unowned let workspace: Workspace
    @Published var sessions: [TerminalSession] = []
    @Published var selected: UUID?

    init(workspace: Workspace) { self.workspace = workspace }

    var current: TerminalSession? { sessions.first { $0.id == selected } ?? sessions.first }

    @discardableResult
    func newTerminal(command: String? = nil, title: String = "Local") -> TerminalSession {
        var command = command, title = title
        // In a remote folder, terminals open on the server.
        if command == nil, let r = workspace.remote { command = Remote.remoteShell(r.spec, command: nil); title = r.spec.host }
        let s = TerminalSession(title: title, cwd: workspace.root, command: nil, isRun: false)
        sessions.append(s)
        selected = s.id
        workspace.bottomTab = .terminal
        workspace.bottomVisible = true
        if let command { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { s.send(command + "\n") } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { s.view.window?.makeFirstResponder(s.view) }
        return s
    }

    func close(_ s: TerminalSession) {
        s.terminate()
        sessions.removeAll { $0.id == s.id }
        if selected == s.id { selected = sessions.last?.id }
    }

    func closeAll() { sessions.forEach { $0.terminate() }; sessions = [] }

    func ensureOne() { if sessions.isEmpty { newTerminal() } }
}

struct RunConfig: Identifiable, Hashable, Codable {
    var id: String { name }
    var name: String
    var command: String
    var custom = false
    static let currentFile = RunConfig(name: "Current File", command: "")
}

@MainActor
final class RunManager: ObservableObject {
    unowned let workspace: Workspace
    @Published var configs: [RunConfig] = []
    @Published var selectedName: String = RunConfig.currentFile.name
    @Published var runs: [TerminalSession] = []
    @Published var selectedRun: UUID?

    init(workspace: Workspace) { self.workspace = workspace }

    private var root: URL { workspace.root }
    private var storeKey: String { "runConfigs:" + root.path }

    var selected: RunConfig { configs.first { $0.name == selectedName } ?? .currentFile }
    var isRunning: Bool { runs.contains { $0.running } }

    /// Detects run configurations from project files (like JetBrains' auto-created configurations).
    func detect() {
        let fm = FileManager.default
        func has(_ f: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent(f).path) }
        var list: [RunConfig] = [.currentFile]
        if has("Package.swift") {
            list += [RunConfig(name: "swift run", command: "swift run"), RunConfig(name: "swift build", command: "swift build"), RunConfig(name: "swift test", command: "swift test")]
        }
        if has("package.json"), let data = try? Data(contentsOf: root.appendingPathComponent("package.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? JSON, let scripts = json["scripts"] as? [String: Any] {
            let pm = has("pnpm-lock.yaml") ? "pnpm" : has("yarn.lock") ? "yarn" : (has("bun.lockb") || has("bun.lock")) ? "bun run" : "npm run"
            let order = ["dev", "start", "build", "test", "lint"]
            for name in scripts.keys.sorted(by: { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }) {
                list.append(RunConfig(name: "\(pm.split(separator: " ").first!) \(name)", command: "\(pm) \(name)"))
            }
        }
        if has("Cargo.toml") { list += [RunConfig(name: "cargo run", command: "cargo run"), RunConfig(name: "cargo test", command: "cargo test"), RunConfig(name: "cargo build", command: "cargo build")] }
        if has("go.mod") { list += [RunConfig(name: "go run .", command: "go run ."), RunConfig(name: "go test", command: "go test ./...")] }
        if has("gradlew") { list += [RunConfig(name: "gradle run", command: "./gradlew run"), RunConfig(name: "gradle build", command: "./gradlew build")] }
        else if has("build.gradle") || has("build.gradle.kts") { list.append(RunConfig(name: "gradle build", command: "gradle build")) }
        if has("pom.xml") { list += [RunConfig(name: "mvn package", command: "mvn package"), RunConfig(name: "mvn test", command: "mvn test")] }
        if has("pyproject.toml") || has("requirements.txt") {
            if has("manage.py") { list.append(RunConfig(name: "django runserver", command: "python3 manage.py runserver")) }
            if has("main.py") { list.append(RunConfig(name: "python main.py", command: "python3 main.py")) }
            list.append(RunConfig(name: "pytest", command: "python3 -m pytest"))
        }
        if has("Gemfile") { list.append(RunConfig(name: "bundle install", command: "bundle install")) }
        if has("mix.exs") { list += [RunConfig(name: "mix run", command: "mix run"), RunConfig(name: "mix test", command: "mix test")] }
        if has("Makefile"), let text = try? String(contentsOf: root.appendingPathComponent("Makefile"), encoding: .utf8) {
            let targets = text.split(separator: "\n").compactMap { l -> String? in
                guard let c = l.firstIndex(of: ":"), !l.hasPrefix("\t"), !l.hasPrefix("."), !l.contains("="), !l.hasPrefix("#") else { return nil }
                let t = l[..<c].trimmingCharacters(in: .whitespaces)
                return t.isEmpty || t.contains(" ") || t.contains("$") ? nil : t
            }
            list.append(RunConfig(name: "make", command: "make"))
            for t in targets.prefix(12) where t != "all" { list.append(RunConfig(name: "make \(t)", command: "make \(t)")) }
        }
        if has("docker-compose.yml") || has("compose.yaml") || has("docker-compose.yaml") { list.append(RunConfig(name: "docker compose up", command: "docker compose up")) }
        if let data = UserDefaults.standard.data(forKey: storeKey), let custom = try? JSONDecoder().decode([RunConfig].self, from: data) {
            list += custom
        }
        configs = list
        if let saved = UserDefaults.standard.string(forKey: storeKey + ".selected"), list.contains(where: { $0.name == saved }) {
            selectedName = saved
        } else if list.count > 1 {
            selectedName = list[1].name
        }
    }

    func select(_ name: String) {
        selectedName = name
        UserDefaults.standard.set(name, forKey: storeKey + ".selected")
    }

    func addCustom(name: String, command: String) {
        var custom = configs.filter(\.custom)
        custom.removeAll { $0.name == name }
        custom.append(RunConfig(name: name, command: command, custom: true))
        if let data = try? JSONEncoder().encode(custom) { UserDefaults.standard.set(data, forKey: storeKey) }
        detect()
        select(name)
    }

    func removeCustom(_ name: String) {
        let custom = configs.filter { $0.custom && $0.name != name }
        if let data = try? JSONEncoder().encode(custom) { UserDefaults.standard.set(data, forKey: storeKey) }
        detect()
    }

    /// Command for running the active file on its own.
    func currentFileCommand() -> (String, String)? {
        guard let doc = workspace.active else { return nil }
        guard let template = doc.language.runFile else { return nil }
        let file = doc.url.path
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("zide-run-" + doc.url.deletingPathExtension().lastPathComponent).path
        let cmd = template
            .replacingOccurrences(of: "{file}", with: Shell.quote(file))
            .replacingOccurrences(of: "{dir}", with: Shell.quote(doc.url.deletingLastPathComponent().path))
            .replacingOccurrences(of: "{name}", with: doc.url.deletingPathExtension().lastPathComponent)
            .replacingOccurrences(of: "{out}", with: Shell.quote(out))
        return (doc.name, cmd)
    }

    func run(_ config: RunConfig? = nil) {
        let cfg = config ?? selected
        workspace.saveAll()
        var title = cfg.name, command = cfg.command
        if cfg.name == RunConfig.currentFile.name {
            guard let (t, c) = currentFileCommand() else {
                workspace.flash(workspace.active.map { "Don't know how to run \($0.language.name) files — add a run configuration" } ?? "Open a file to run it")
                return
            }
            title = t; command = c
        }
        // Re-running replaces the previous run of the same configuration (like JetBrains).
        if let old = runs.first(where: { $0.title == title }) {
            old.terminate()
            runs.removeAll { $0.id == old.id }
        }
        if let r = workspace.remote { command = Remote.remoteShell(r.spec, command: command) }     // runs on the server
        let s = TerminalSession(title: title, cwd: root, command: command, isRun: true)
        runs.append(s)
        selectedRun = s.id
        workspace.bottomTab = .run
        workspace.bottomVisible = true
    }

    func stop() {
        for r in runs where r.running { r.terminate() }
    }

    func close(_ s: TerminalSession) {
        s.terminate()
        runs.removeAll { $0.id == s.id }
        if selectedRun == s.id { selectedRun = runs.last?.id }
    }

    var currentRun: TerminalSession? { runs.first { $0.id == selectedRun } ?? runs.last }
}
