import Foundation

/// Debugs JavaScript / TypeScript with Node's built-in inspector (Chrome DevTools Protocol over a WebSocket).
/// TypeScript runs with --experimental-strip-types, which keeps line numbers, so breakpoints map 1:1.
@MainActor
final class NodeBackend: DebugBackend {
    private let events: DebugEvents
    private let file: String
    private let typescript: Bool
    private let cwd: URL
    private let process = Process()
    private let out = Pipe(), err = Pipe()
    private var socket: URLSessionWebSocketTask?
    private var nextID = 1
    private var pending: [Int: (JSON) -> Void] = [:]
    private var callFrames: [JSON] = []
    private var refs: [Int: String] = [:]          // VarNode reference → CDP objectId
    private var breakpointIDs: [String: [String]] = [:]
    private var scriptURLs: [String: String] = [:]   // scriptId → url (from Debugger.scriptParsed)
    private var sawInitialBreak = false
    private var stderrBuffer = ""
    private var finished = false

    init(events: DebugEvents, file: String, typescript: Bool, cwd: URL) {
        self.events = events
        self.file = file
        self.typescript = typescript
        self.cwd = cwd
    }

    func start() {
        guard let node = Env.which("node") else { events.output("node not found", .error); events.terminated(); return }
        process.executableURL = URL(fileURLWithPath: node)
        var args = ["--inspect-brk=127.0.0.1:0"]
        if typescript { args += ["--experimental-strip-types", "--no-warnings=ExperimentalWarning"] }
        process.arguments = args + [file]
        process.environment = Env.environment
        process.currentDirectoryURL = cwd
        process.standardOutput = out
        process.standardError = err
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            guard !s.isEmpty else { return }
            DispatchQueue.main.async { self?.events.output(s, .stdout) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            guard !s.isEmpty else { return }
            DispatchQueue.main.async { self?.stderr(s) }
        }
        process.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.end() } }
        do { try process.run() } catch { events.output(error.localizedDescription, .error); events.terminated() }
    }

    /// Node prints the inspector URL and lifecycle notices on stderr; everything else is program output.
    private func stderr(_ s: String) {
        stderrBuffer += s
        while let nl = stderrBuffer.firstIndex(of: "\n") {
            let line = String(stderrBuffer[..<nl])
            stderrBuffer = String(stderrBuffer[stderrBuffer.index(after: nl)...])
            if let r = line.range(of: "ws://"), socket == nil, let url = URL(string: String(line[r.lowerBound...]).trimmingCharacters(in: .whitespaces)) {
                connect(url)
            } else if line.contains("Waiting for the debugger to disconnect") {
                end()
            } else if line.hasPrefix("Debugger listening") || line.hasPrefix("For help, see") || line.hasPrefix("Debugger attached") || line.isEmpty {
                continue
            } else {
                events.output(line, .stderr)
            }
        }
    }

    private func connect(_ url: URL) {
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        receive()
        send("Runtime.enable")
        send("Debugger.enable") { [weak self] _ in
            guard let self else { return }
            self.events.ready()                       // manager sends setBreakpoints now
            self.send("Runtime.runIfWaitingForDebugger")
        }
    }

    private func receive() {
        socket?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                guard case .success(let msg) = result else { return }
                var text: String?
                if case .string(let s) = msg { text = s } else if case .data(let d) = msg { text = String(decoding: d, as: UTF8.self) }
                if let text, let data = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? JSON { self.handle(obj) }
                self.receive()
            }
        }
    }

    private func send(_ method: String, _ params: JSON = [:], _ done: ((JSON) -> Void)? = nil) {
        let id = nextID
        nextID += 1
        if let done { pending[id] = done }
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]),
              let s = String(data: data, encoding: .utf8) else { return }
        socket?.send(.string(s)) { _ in }
    }

    private func handle(_ msg: JSON) {
        if let id = msg["id"] as? Int, let cb = pending.removeValue(forKey: id) {
            cb((msg["result"] as? JSON) ?? ["error": msg["error"] ?? "error"])
            return
        }
        guard let method = msg["method"] as? String else { return }
        let params = msg["params"] as? JSON ?? [:]
        switch method {
        case "Debugger.paused":
            callFrames = params["callFrames"] as? [JSON] ?? []
            let reason = params["reason"] as? String ?? "paused"
            let hitBreakpoints = (params["hitBreakpoints"] as? [String]) ?? []
            // --inspect-brk pauses on the first line; continue unless a breakpoint is there.
            if !sawInitialBreak && hitBreakpoints.isEmpty && (reason == "Break on start" || reason == "other") {
                sawInitialBreak = true
                send("Debugger.resume")
                return
            }
            sawInitialBreak = true
            events.stopped(hitBreakpoints.isEmpty ? (reason == "other" ? "step" : reason) : "breakpoint")
        case "Debugger.scriptParsed":
            if let id = params["scriptId"] as? String, let url = params["url"] as? String, !url.isEmpty { scriptURLs[id] = url }
        case "Debugger.resumed":
            events.continued()
        case "Runtime.exceptionThrown":
            let d = (params["exceptionDetails"] as? JSON)
            let text = ((d?["exception"] as? JSON)?["description"] as? String) ?? (d?["text"] as? String) ?? "Exception"
            events.output(text, .stderr)
        default: break
        }
    }

    private func end() {
        guard !finished else { return }
        finished = true
        socket?.cancel(with: .goingAway, reason: nil)
        if process.isRunning { process.terminate() }
        events.output("Process finished", .info)
        events.terminated()
    }

    // MARK: DebugBackend

    func setBreakpoints(path: String, lines: [(line: Int, condition: String)]) {
        for id in breakpointIDs[path] ?? [] { send("Debugger.removeBreakpoint", ["breakpointId": id]) }
        breakpointIDs[path] = []
        let pattern = NSRegularExpression.escapedPattern(for: path) + "$"
        for l in lines {
            var p: JSON = ["lineNumber": l.line - 1, "urlRegex": pattern]
            if !l.condition.isEmpty { p["condition"] = l.condition }
            send("Debugger.setBreakpointByUrl", p) { [weak self] r in
                if let id = r["breakpointId"] as? String { self?.breakpointIDs[path, default: []].append(id) }
            }
        }
    }

    func resume() { send("Debugger.resume") }
    func stepOver() { send("Debugger.stepOver") }
    func stepInto() { send("Debugger.stepInto") }
    func stepOut() { send("Debugger.stepOut") }
    func pause() { send("Debugger.pause") }
    func stop() { end() }

    func stackTrace(_ done: @escaping ([StackFrame]) -> Void) {
        done(callFrames.enumerated().map { i, f in
            let loc = f["location"] as? JSON
            var urlString = f["url"] as? String ?? ""
            if urlString.isEmpty, let sid = loc?["scriptId"] as? String { urlString = scriptURLs[sid] ?? "" }
            let url: URL? = urlString.hasPrefix("file://") ? URL(string: urlString) : (urlString.hasPrefix("/") ? URL(fileURLWithPath: urlString) : nil)
            let line = (loc?["lineNumber"] as? Int ?? 0) + 1
            let name = (f["functionName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(anonymous)"
            return StackFrame(id: i, name: name, url: url?.standardizedFileURL, line: line)
        })
    }

    private func ref(_ objectId: String) -> Int {
        let r = refs.count + 1
        refs[r] = objectId
        return r
    }

    func scopes(frame: StackFrame, _ done: @escaping ([VarNode]) -> Void) {
        guard callFrames.indices.contains(frame.id) else { done([]); return }
        let chain = callFrames[frame.id]["scopeChain"] as? [JSON] ?? []
        done(chain.compactMap { s in
            guard let oid = (s["object"] as? JSON)?["objectId"] as? String else { return nil }
            let type = s["type"] as? String ?? "scope"
            return VarNode(name: type.prefix(1).uppercased() + type.dropFirst(), value: "", type: "", reference: ref(oid))
        })
    }

    func variables(reference: Int, _ done: @escaping ([VarNode]) -> Void) {
        guard let oid = refs[reference] else { done([]); return }
        send("Runtime.getProperties", ["objectId": oid, "ownProperties": true, "generatePreview": false]) { [weak self] r in
            guard let self else { return }
            let props = (r["result"] as? [JSON]) ?? []
            done(props.prefix(400).compactMap { p in
                guard let name = p["name"] as? String, name != "__proto__", let v = p["value"] as? JSON else { return nil }
                let (text, type, oid) = Self.describe(v)
                return VarNode(name: name, value: text, type: type, reference: oid.map { self.ref($0) } ?? 0)
            })
        }
    }

    private static func describe(_ v: JSON) -> (String, String, String?) {
        let type = (v["subtype"] as? String) ?? (v["type"] as? String) ?? ""
        let oid = v["objectId"] as? String
        if let d = v["description"] as? String { return (type == "string" ? "\"\(d)\"" : d, type, oid) }
        if let s = v["value"] as? String { return ("\"\(s)\"", type, oid) }
        if let val = v["value"] { return ("\(val)", type, oid) }
        return (type == "undefined" ? "undefined" : type, type, oid)
    }

    func evaluate(_ expression: String, frame: StackFrame?, _ done: @escaping (String, Bool) -> Void) {
        let handler: (JSON) -> Void = { r in
            if let ex = r["exceptionDetails"] as? JSON {
                done(((ex["exception"] as? JSON)?["description"] as? String) ?? (ex["text"] as? String) ?? "error", false)
            } else if let v = r["result"] as? JSON {
                done(Self.describe(v).0, true)
            } else { done("error", false) }
        }
        if let frame, callFrames.indices.contains(frame.id), let cfid = callFrames[frame.id]["callFrameId"] as? String {
            send("Debugger.evaluateOnCallFrame", ["callFrameId": cfid, "expression": expression], handler)
        } else {
            send("Runtime.evaluate", ["expression": expression], handler)
        }
    }
}
