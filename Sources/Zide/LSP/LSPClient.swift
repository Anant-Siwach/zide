import Foundation

typealias JSON = [String: Any]

/// A JSON-RPC client for one language server process, speaking LSP over stdio.
final class LSPClient {
    enum State: Equatable { case starting, ready, failed(String), stopped }

    let spec: ServerSpec
    let executable: String
    let root: URL
    private(set) var state: State = .starting { didSet { onStateChange?(state) } }
    private(set) var capabilities: JSON = [:]

    var onNotification: ((String, Any?) -> Void)?
    var onStateChange: ((State) -> Void)?
    /// Server → client requests that need workspace access (applyEdit, showDocument…).
    var onRequest: ((String, Any?, @escaping (Any?) -> Void) -> Void)?

    private let process = Process()
    private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    private let queue = DispatchQueue(label: "zide.lsp")
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: (Result<Any?, Error>) -> Void] = [:]
    private var readyWaiters: [() -> Void] = []
    private(set) var stderrTail = ""

    struct LSPError: LocalizedError { let message: String; var errorDescription: String? { message } }

    init(spec: ServerSpec, executable: String, root: URL) {
        self.spec = spec
        self.executable = executable
        self.root = root
    }

    // MARK: Lifecycle

    func start() {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = spec.args
        process.environment = Env.environment
        process.currentDirectoryURL = root
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.receive(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            self?.queue.async { self?.stderrTail = String(((self?.stderrTail ?? "") + s).suffix(4000)) }
        }
        process.terminationHandler = { [weak self] p in
            self?.queue.async {
                guard let self else { return }
                if self.state != .stopped { self.state = .failed("exited (\(p.terminationStatus))") }
                for (_, cb) in self.pending { cb(.failure(LSPError(message: "server exited"))) }
                self.pending = [:]
            }
        }
        do { try process.run() } catch {
            state = .failed(error.localizedDescription)
            return
        }
        initialize()
    }

    func stop() {
        guard process.isRunning else { return }
        request("shutdown", nil) { [weak self] _ in
            self?.notify("exit", nil)
            self?.state = .stopped
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if self?.process.isRunning == true { self?.process.terminate() } }
        }
    }

    private func initialize() {
        let params: JSON = [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "clientInfo": ["name": "Zide", "version": "1.0"],
            "rootUri": root.absoluteString,
            "rootPath": root.path,
            "workspaceFolders": [["uri": root.absoluteString, "name": root.lastPathComponent]],
            "initializationOptions": spec.initOptions ?? [:],
            "capabilities": [
                "general": ["positionEncodings": ["utf-16"]],
                "workspace": [
                    "applyEdit": true, "workspaceFolders": true, "configuration": true,
                    "workspaceEdit": ["documentChanges": true],
                    "symbol": ["dynamicRegistration": false],
                    "didChangeWatchedFiles": ["dynamicRegistration": false],
                ],
                "window": ["workDoneProgress": true, "showDocument": ["support": true]],
                "textDocument": [
                    "synchronization": ["didSave": true, "willSave": false, "dynamicRegistration": false],
                    "completion": [
                        "completionItem": ["snippetSupport": true, "documentationFormat": ["markdown", "plaintext"],
                                           "resolveSupport": ["properties": ["documentation", "detail"]], "insertReplaceSupport": false,
                                           "labelDetailsSupport": true],
                        "contextSupport": true,
                    ],
                    "hover": ["contentFormat": ["markdown", "plaintext"]],
                    "signatureHelp": ["signatureInformation": ["documentationFormat": ["markdown", "plaintext"]]],
                    "definition": ["linkSupport": true], "declaration": ["linkSupport": true],
                    "typeDefinition": ["linkSupport": true], "implementation": ["linkSupport": true],
                    "references": [:], "documentHighlight": [:],
                    "documentSymbol": ["hierarchicalDocumentSymbolSupport": true],
                    "formatting": [:], "rangeFormatting": [:], "rename": ["prepareSupport": false],
                    "codeAction": ["codeActionLiteralSupport": ["codeActionKind": ["valueSet": ["", "quickfix", "refactor", "refactor.extract", "refactor.inline", "refactor.rewrite", "source", "source.organizeImports"]]]],
                    "publishDiagnostics": ["relatedInformation": false, "versionSupport": false],
                    "inlayHint": [:],
                ],
            ],
        ]
        request("initialize", params) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let r):
                self.capabilities = ((r as? JSON)?["capabilities"] as? JSON) ?? [:]
                self.notify("initialized", [:] as JSON)
                self.state = .ready
                let waiters = self.readyWaiters
                self.readyWaiters = []
                waiters.forEach { $0() }
            case .failure(let e):
                self.state = .failed(e.localizedDescription)
            }
        }
    }

    /// Runs `block` once the server has initialized.
    func whenReady(_ block: @escaping () -> Void) {
        queue.async {
            if self.state == .ready { block() } else if case .starting = self.state { self.readyWaiters.append(block) }
        }
    }

    // MARK: Capabilities

    func supports(_ key: String) -> Bool {
        guard let v = capabilities[key] else { return false }
        if let b = v as? Bool { return b }
        return true
    }

    var triggerCharacters: Set<String> {
        Set(((capabilities["completionProvider"] as? JSON)?["triggerCharacters"] as? [String]) ?? [])
    }

    var signatureTriggers: Set<String> {
        Set(((capabilities["signatureHelpProvider"] as? JSON)?["triggerCharacters"] as? [String]) ?? [])
    }

    /// 1 = full sync, 2 = incremental.
    var syncKind: Int {
        if let n = capabilities["textDocumentSync"] as? Int { return n }
        return ((capabilities["textDocumentSync"] as? JSON)?["change"] as? Int) ?? 1
    }

    // MARK: Messaging

    func request(_ method: String, _ params: Any?, _ completion: @escaping (Result<Any?, Error>) -> Void) {
        queue.async {
            let id = self.nextID
            self.nextID += 1
            self.pending[id] = completion
            var msg: JSON = ["jsonrpc": "2.0", "id": id, "method": method]
            if let params { msg["params"] = params }
            self.send(msg)
        }
    }

    /// Async helper that returns the raw result on the main actor.
    func request(_ method: String, _ params: Any?) async throws -> Any? {
        try await withCheckedThrowingContinuation { cont in
            request(method, params) { cont.resume(with: $0) }
        }
    }

    func notify(_ method: String, _ params: Any?) {
        queue.async {
            var msg: JSON = ["jsonrpc": "2.0", "method": method]
            if let params { msg["params"] = params }
            self.send(msg)
        }
    }

    func cancel(_ id: Int) { notify("$/cancelRequest", ["id": id]) }

    private func send(_ msg: JSON) {
        guard process.isRunning, let body = try? JSONSerialization.data(withJSONObject: msg) else { return }
        var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        data.append(body)
        try? stdin.fileHandleForWriting.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        let separator = Data("\r\n\r\n".utf8)
        while let headerEnd = buffer.range(of: separator) {
            let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            guard let lenLine = header.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length") }),
                  let length = Int(lenLine.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") else {
                buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound)
                continue
            }
            let bodyStart = headerEnd.upperBound
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return }
            let bodyEnd = buffer.index(bodyStart, offsetBy: length)
            let body = buffer[bodyStart..<bodyEnd]
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)
            buffer = Data(buffer)
            if let obj = try? JSONSerialization.jsonObject(with: body) as? JSON { handle(obj) }
        }
    }

    private func handle(_ msg: JSON) {
        let method = msg["method"] as? String
        if let id = msg["id"], let method {
            // Request from the server.
            respondToServer(id: id, method: method, params: msg["params"])
            return
        }
        if let method {
            let params = msg["params"]
            DispatchQueue.main.async { self.onNotification?(method, params) }
            return
        }
        guard let id = (msg["id"] as? Int) ?? (msg["id"] as? NSNumber)?.intValue, let cb = pending.removeValue(forKey: id) else { return }
        if let err = msg["error"] as? JSON {
            let message = err["message"] as? String ?? "error"
            DispatchQueue.main.async { cb(.failure(LSPError(message: message))) }
        } else {
            let result = msg["result"] is NSNull ? nil : msg["result"]
            DispatchQueue.main.async { cb(.success(result)) }
        }
    }

    private func respondToServer(id: Any, method: String, params: Any?) {
        let reply: (Any?) -> Void = { [weak self] result in
            self?.queue.async { self?.send(["jsonrpc": "2.0", "id": id, "result": result ?? NSNull()]) }
        }
        switch method {
        case "workspace/configuration":
            let items = ((params as? JSON)?["items"] as? [Any]) ?? []
            reply(items.map { _ in NSNull() })
        case "client/registerCapability", "client/unregisterCapability", "window/workDoneProgress/create":
            reply(nil)
        case "workspace/workspaceFolders":
            reply([["uri": root.absoluteString, "name": root.lastPathComponent]])
        default:
            DispatchQueue.main.async {
                if let onRequest = self.onRequest { onRequest(method, params, reply) } else { reply(nil) }
            }
        }
    }
}

// MARK: - Position helpers

extension NSString {
    /// UTF-16 offset of an LSP position.
    func offset(line: Int, character: Int) -> Int {
        var currentLine = 0, idx = 0
        let len = length
        while currentLine < line && idx < len {
            let r = lineRange(for: NSRange(location: idx, length: 0))
            idx = NSMaxRange(r)
            currentLine += 1
        }
        let lineR = lineRange(for: NSRange(location: min(idx, len), length: 0))
        var contentEnd = NSMaxRange(lineR)
        while contentEnd > lineR.location && (self.character(at: contentEnd - 1) == 10 || self.character(at: contentEnd - 1) == 13) { contentEnd -= 1 }
        return min(idx + character, max(contentEnd, idx))
    }

    func position(of offset: Int) -> (line: Int, character: Int) {
        let o = min(max(0, offset), length)
        var line = 0, idx = 0
        while idx < o {
            let r = lineRange(for: NSRange(location: idx, length: 0))
            if NSMaxRange(r) > o { break }
            idx = NSMaxRange(r)
            line += 1
        }
        return (line, o - idx)
    }

    func lspPosition(_ offset: Int) -> JSON {
        let p = position(of: offset)
        return ["line": p.line, "character": p.character]
    }

    func range(lsp r: JSON) -> NSRange? {
        guard let s = r["start"] as? JSON, let e = r["end"] as? JSON else { return nil }
        let a = offset(line: s["line"] as? Int ?? 0, character: s["character"] as? Int ?? 0)
        let b = offset(line: e["line"] as? Int ?? 0, character: e["character"] as? Int ?? 0)
        return NSRange(location: min(a, b), length: abs(b - a))
    }
}

/// Helpers for LSP payloads.
enum LSP {
    static func markdown(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let d = any as? JSON {
            if let v = d["value"] as? String {
                if let lang = d["language"] as? String { return "```\(lang)\n\(v)\n```" }
                return v
            }
        }
        if let arr = any as? [Any] { return arr.map { markdown($0) }.filter { !$0.isEmpty }.joined(separator: "\n\n") }
        return ""
    }

    /// Normalises Location | Location[] | LocationLink[] into (uri, range).
    static func locations(_ any: Any?) -> [(URL, JSON)] {
        var items: [JSON] = []
        if let d = any as? JSON { items = [d] } else if let a = any as? [JSON] { items = a }
        return items.compactMap { d in
            let uri = (d["uri"] as? String) ?? (d["targetUri"] as? String)
            let range = (d["range"] as? JSON) ?? (d["targetSelectionRange"] as? JSON) ?? (d["targetRange"] as? JSON)
            guard let uri, let url = URL(string: uri), let range else { return nil }
            return (url, range)
        }
    }

    /// Strips snippet syntax: ${1:name} → name, $0 / $1 → "". Returns text and the first tab stop offset.
    static func expandSnippet(_ s: String) -> (text: String, cursor: Int?) {
        var out = "", cursor: Int?
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "\\", s.index(after: i) < s.endIndex {
                out.append(s[s.index(after: i)]); i = s.index(i, offsetBy: 2); continue
            }
            if c == "$" {
                let n = s.index(after: i)
                if n < s.endIndex, s[n] == "{" {
                    var depth = 1, j = s.index(after: n)
                    var body = ""
                    while j < s.endIndex && depth > 0 {
                        if s[j] == "{" { depth += 1 } else if s[j] == "}" { depth -= 1; if depth == 0 { break } }
                        body.append(s[j]); j = s.index(after: j)
                    }
                    let parts = body.split(separator: ":", maxSplits: 1)
                    if cursor == nil { cursor = out.utf16.count }
                    if parts.count == 2 { out += expandSnippet(String(parts[1])).text }
                    else if body.contains("|") { out += body.split(separator: "|").dropFirst().first.map(String.init)?.split(separator: ",").first.map(String.init) ?? "" }
                    i = j < s.endIndex ? s.index(after: j) : j
                    continue
                }
                if n < s.endIndex, s[n].isNumber {
                    var j = n
                    while j < s.endIndex && s[j].isNumber { j = s.index(after: j) }
                    if cursor == nil || s[n] == "0" && cursor == nil { cursor = out.utf16.count }
                    i = j; continue
                }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return (out, cursor)
    }
}
