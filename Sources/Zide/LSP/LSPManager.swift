import AppKit

/// Starts one language server per language (lazily) for a workspace and routes documents to it.
@MainActor
final class LSPManager: ObservableObject {
    enum Status: Equatable {
        case none                       // no server known for this language
        case missing(ServerSpec)        // known but not installed
        case starting(String)
        case ready(String)
        case failed(String, String)

        static func == (a: Status, b: Status) -> Bool {
            switch (a, b) {
            case (.none, .none): return true
            case (.missing(let x), .missing(let y)): return x.command == y.command
            case (.starting(let x), .starting(let y)), (.ready(let x), .ready(let y)): return x == y
            case (.failed(let x, let m), .failed(let y, let n)): return x == y && m == n
            default: return false
            }
        }
    }

    @Published private(set) var statuses: [String: Status] = [:]
    @Published var progress: String?
    private var clients: [String: LSPClient] = [:]
    private var openDocs: [String: Set<String>] = [:]
    private var changeTimers: [ObjectIdentifier: Timer] = [:]
    unowned let workspace: Workspace

    init(workspace: Workspace) { self.workspace = workspace }

    static func key(_ lang: Language) -> String { lang.serverID ?? lang.id }

    func status(for lang: Language) -> Status {
        if let s = statuses[Self.key(lang)] { return s }
        guard let spec = lang.servers.first else { return .none }
        return Self.resolve(lang) == nil ? .missing(spec) : .starting(spec.command)
    }

    /// The first installed server for a language.
    nonisolated static func resolve(_ lang: Language) -> (ServerSpec, String)? {
        for spec in lang.servers {
            if let path = Env.which(spec.command) {
                // rustup installs proxy binaries that fail until the component is added.
                if path.contains("/.cargo/bin/") || path.contains("/.rustup/"), !Shell.run(path, ["--version"]).ok { continue }
                return (spec, path)
            }
            if spec.command == "sourcekit-lsp" || spec.command == "clangd" {
                let r = Shell.run("xcrun", ["--find", spec.command])
                let p = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
                if r.ok && !p.isEmpty { return (spec, p) }
            }
        }
        return nil
    }

    func client(for lang: Language) -> LSPClient? {
        let key = Self.key(lang)
        if let c = clients[key] { return c }
        guard !lang.servers.isEmpty, statuses[key] == nil else { return nil }
        statuses[key] = .starting(lang.servers[0].command)
        Task.detached { [weak self] in
            let resolved = Self.resolve(lang)
            await MainActor.run { self?.launch(key: key, lang: lang, resolved: resolved) }
        }
        return nil
    }

    private func launch(key: String, lang: Language, resolved: (ServerSpec, String)?) {
        guard let (spec, path) = resolved else {
            statuses[key] = .missing(lang.servers[0])
            return
        }
        let c = LSPClient(spec: spec, executable: path, root: workspace.root)
        clients[key] = c
        c.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.statuses[key] = .ready(spec.command)
                    for d in self?.workspace.documents ?? [] where Self.key(d.language) == key {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { d.primaryEditor.scheduleInlayHints(delay: 0) }
                    }
                case .failed(let m): self?.statuses[key] = .failed(spec.command, m + (c.stderrTail.isEmpty ? "" : "\n" + c.stderrTail.suffix(600)))
                case .starting: self?.statuses[key] = .starting(spec.command)
                case .stopped: self?.statuses[key] = nil
                }
            }
        }
        c.onNotification = { [weak self] method, params in self?.notification(method, params) }
        c.onRequest = { [weak self] method, params, reply in self?.serverRequest(method, params, reply) }
        c.start()
        // Open every already-open document of this server's languages.
        for doc in workspace.documents where Self.key(doc.language) == key { didOpen(doc) }
    }

    func restart(_ lang: Language) {
        let key = Self.key(lang)
        clients.removeValue(forKey: key)?.stop()
        statuses[key] = nil
        openDocs[key] = nil
        for doc in workspace.documents where Self.key(doc.language) == key { didOpen(doc) }
    }

    func stopAll() {
        clients.values.forEach { $0.stop() }
        clients = [:]
    }

    // MARK: Document sync

    func didOpen(_ doc: EditorDocument) {
        guard !doc.isBinary, !doc.isTooLarge, let c = client(for: doc.language) else { return }
        let key = Self.key(doc.language)
        guard openDocs[key, default: []].insert(doc.uri).inserted else { return }
        c.whenReady {
            DispatchQueue.main.async {
                c.notify("textDocument/didOpen", ["textDocument": ["uri": doc.uri, "languageId": doc.language.id, "version": doc.version, "text": doc.text]])
            }
        }
    }

    func didChange(_ doc: EditorDocument) {
        let oid = ObjectIdentifier(doc)
        changeTimers[oid]?.invalidate()
        changeTimers[oid] = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self, weak doc] _ in
            MainActor.assumeIsolated {
                guard let self, let doc else { return }
                self.flushChange(doc)
            }
        }
    }

    /// Sends pending changes immediately (before completion / hover requests).
    func flushChange(_ doc: EditorDocument) {
        let oid = ObjectIdentifier(doc)
        guard let t = changeTimers.removeValue(forKey: oid) else { return }
        t.invalidate()
        guard let c = clients[Self.key(doc.language)], openDocs[Self.key(doc.language)]?.contains(doc.uri) == true else { return }
        c.notify("textDocument/didChange", ["textDocument": ["uri": doc.uri, "version": doc.version], "contentChanges": [["text": doc.text]]])
    }

    func didSave(_ doc: EditorDocument) {
        flushChange(doc)
        clients[Self.key(doc.language)]?.notify("textDocument/didSave", ["textDocument": ["uri": doc.uri], "text": doc.text])
    }

    func didClose(_ doc: EditorDocument) {
        let key = Self.key(doc.language)
        guard openDocs[key]?.remove(doc.uri) != nil else { return }
        clients[key]?.notify("textDocument/didClose", ["textDocument": ["uri": doc.uri]])
    }

    // MARK: Requests

    /// Sends a position-based request for `doc` at `offset`.
    func request(_ method: String, _ doc: EditorDocument, offset: Int, extra: JSON = [:]) async -> Any? {
        guard let c = clients[Self.key(doc.language)], c.state == .ready else { return nil }
        flushChange(doc)
        var params: JSON = ["textDocument": ["uri": doc.uri], "position": doc.lineIndex.position(offset)]
        for (k, v) in extra { params[k] = v }
        return try? await c.request(method, params)
    }

    func request(_ method: String, _ doc: EditorDocument, params: JSON) async -> Any? {
        guard let c = clients[Self.key(doc.language)], c.state == .ready else { return nil }
        flushChange(doc)
        var p = params
        p["textDocument"] = ["uri": doc.uri]
        return try? await c.request(method, p)
    }

    func client(of doc: EditorDocument) -> LSPClient? {
        guard let c = clients[Self.key(doc.language)], c.state == .ready else { return nil }
        return c
    }

    /// workspace/symbol across every running server.
    func workspaceSymbols(_ query: String) async -> [(name: String, detail: String, url: URL, range: JSON, kind: Int)] {
        var out: [(String, String, URL, JSON, Int)] = []
        for c in clients.values where c.state == .ready && c.supports("workspaceSymbolProvider") {
            guard let r = try? await c.request("workspace/symbol", ["query": query]) as? [JSON] else { continue }
            for s in r.prefix(200) {
                let loc = s["location"] as? JSON
                guard let uri = loc?["uri"] as? String, let url = URL(string: uri) else { continue }
                out.append((s["name"] as? String ?? "", s["containerName"] as? String ?? "", url, loc?["range"] as? JSON ?? [:], s["kind"] as? Int ?? 0))
            }
        }
        return out
    }

    // MARK: Server → client

    private func notification(_ method: String, _ params: Any?) {
        let p = params as? JSON
        switch method {
        case "textDocument/publishDiagnostics":
            guard let uri = p?["uri"] as? String, let url = URL(string: uri) else { return }
            workspace.setDiagnostics(url: url, raw: p?["diagnostics"] as? [JSON] ?? [])
        case "window/showMessage":
            if let m = p?["message"] as? String, (p?["type"] as? Int ?? 4) <= 2 { workspace.flash(m) }
        case "$/progress":
            guard let v = p?["value"] as? JSON else { return }
            switch v["kind"] as? String {
            case "begin": progress = [v["title"] as? String, v["message"] as? String].compactMap { $0 }.joined(separator: " — ")
            case "report": if let m = v["message"] as? String { progress = m }
            case "end": progress = nil
            default: break
            }
        default:
            break
        }
    }

    private func serverRequest(_ method: String, _ params: Any?, _ reply: @escaping (Any?) -> Void) {
        let p = params as? JSON
        switch method {
        case "workspace/applyEdit":
            workspace.apply(workspaceEdit: p?["edit"] as? JSON ?? [:])
            reply(["applied": true])
        case "window/showDocument":
            if let uri = p?["uri"] as? String, let url = URL(string: uri) {
                if p?["external"] as? Bool == true { NSWorkspace.shared.open(url) } else { workspace.open(url, range: p?["selection"] as? JSON) }
            }
            reply(["success": true])
        case "window/showMessageRequest":
            reply(nil)
        default:
            reply(nil)
        }
    }
}
