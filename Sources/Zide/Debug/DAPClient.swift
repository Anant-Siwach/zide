import Foundation
import Network

/// A Debug Adapter Protocol client over stdio, or over TCP for adapters that only listen on a port (Delve).
final class DAPClient {
    enum Transport { case stdio(String, [String]), tcp(String, [String], Int) }

    private let process = Process()
    private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    private let transport: Transport
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "zide.dap")
    private var buffer = Data()
    private var seq = 1
    private var pending: [Int: (JSON) -> Void] = [:]
    private(set) var capabilities: JSON = [:]

    var onEvent: ((String, JSON) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onStderr: ((String) -> Void)?
    var onConnected: (() -> Void)?

    init(transport: Transport, cwd: URL) {
        self.transport = transport
        switch transport {
        case .stdio(let exe, let args), .tcp(let exe, let args, _):
            process.executableURL = URL(fileURLWithPath: exe)
            process.arguments = args
        }
        process.environment = Env.environment
        process.currentDirectoryURL = cwd
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    func start() throws {
        let isTCP: Bool
        if case .tcp = transport { isTCP = true } else { isTCP = false }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let self else { return }
            if isTCP {
                // The adapter's own stdout is program/adapter output, not protocol messages.
                let s = String(decoding: d, as: UTF8.self)
                DispatchQueue.main.async { self.onStderr?(s) }
            } else {
                self.queue.async { self.receive(d) }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            if !s.isEmpty { DispatchQueue.main.async { self?.onStderr?(s) } }
        }
        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async { self?.onExit?(p.terminationStatus) }
        }
        try process.run()
        if case .tcp(_, _, let port) = transport { connect(port: port, attempt: 0) } else { DispatchQueue.main.async { self.onConnected?() } }
    }

    private func connect(port: Int, attempt: Int) {
        let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(integerLiteral: UInt16(port)), using: .tcp)
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.connection = c
                self.readLoop(c)
                DispatchQueue.main.async { self.onConnected?() }
            case .failed, .waiting:
                c.cancel()
                guard attempt < 50, self.process.isRunning else { return }
                self.queue.asyncAfter(deadline: .now() + 0.2) { self.connect(port: port, attempt: attempt + 1) }
            default: break
            }
        }
        c.start(queue: queue)
    }

    private func readLoop(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, error in
            if let data, !data.isEmpty { self?.receive(data) }
            if done || error != nil { return }
            self?.readLoop(c)
        }
    }

    func kill() {
        connection?.cancel()
        if process.isRunning { process.terminate() }
    }

    func request(_ command: String, _ args: JSON = [:], _ completion: ((JSON) -> Void)? = nil) {
        queue.async {
            let s = self.seq
            self.seq += 1
            if let completion { self.pending[s] = completion }
            self.send(["seq": s, "type": "request", "command": command, "arguments": args])
        }
    }

    private func send(_ msg: JSON) {
        guard let body = try? JSONSerialization.data(withJSONObject: msg) else { return }
        var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        data.append(body)
        if let connection {
            connection.send(content: data, completion: .contentProcessed { _ in })
        } else if process.isRunning {
            try? stdin.fileHandleForWriting.write(contentsOf: data)
        }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        let sep = Data("\r\n\r\n".utf8)
        while let h = buffer.range(of: sep) {
            let header = String(decoding: buffer[buffer.startIndex..<h.lowerBound], as: UTF8.self)
            guard let line = header.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length") }),
                  let len = Int(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") else {
                buffer.removeSubrange(buffer.startIndex..<h.upperBound); continue
            }
            guard buffer.distance(from: h.upperBound, to: buffer.endIndex) >= len else { return }
            let end = buffer.index(h.upperBound, offsetBy: len)
            let body = buffer[h.upperBound..<end]
            buffer = Data(buffer[end...])
            guard let msg = try? JSONSerialization.jsonObject(with: body) as? JSON else { continue }
            switch msg["type"] as? String {
            case "response":
                if let rs = msg["request_seq"] as? Int, let cb = pending.removeValue(forKey: rs) {
                    if msg["command"] as? String == "initialize" { capabilities = msg["body"] as? JSON ?? [:] }
                    DispatchQueue.main.async { cb(msg) }
                }
            case "event":
                let name = msg["event"] as? String ?? ""
                let body = msg["body"] as? JSON ?? [:]
                DispatchQueue.main.async { self.onEvent?(name, body) }
            case "request":
                // Reverse requests (runInTerminal, startDebugging) aren't supported.
                let rs = msg["seq"] as? Int ?? 0
                send(["seq": seq, "type": "response", "request_seq": rs, "success": false, "command": msg["command"] ?? "", "message": "not supported"])
                seq += 1
            default: break
            }
        }
    }
}

/// DebugBackend over the Debug Adapter Protocol (lldb-dap, debugpy, Delve).
@MainActor
final class DAPBackend: DebugBackend {
    private let events: DebugEvents
    private let client: DAPClient
    private let launch: JSON
    private let adapterID: String
    private var threadId = 1

    init(events: DebugEvents, transport: DAPClient.Transport, cwd: URL, launch: JSON, adapterID: String) {
        self.events = events
        self.client = DAPClient(transport: transport, cwd: cwd)
        self.launch = launch
        self.adapterID = adapterID
    }

    func start() {
        client.onEvent = { [weak self] name, body in self?.event(name, body) }
        client.onExit = { [weak self] _ in self?.events.terminated() }
        client.onStderr = { [weak self] s in self?.events.output(s, .stderr) }
        client.onConnected = { [weak self] in self?.initialize() }
        do { try client.start() } catch {
            events.output("Couldn't start the debug adapter: \(error.localizedDescription)", .error)
            events.terminated()
        }
    }

    private func initialize() {
        client.request("initialize", ["clientID": "zide", "clientName": "Zide", "adapterID": adapterID,
                                      "linesStartAt1": true, "columnsStartAt1": true, "pathFormat": "path",
                                      "supportsVariableType": true, "supportsRunInTerminalRequest": false, "locale": "en"]) { [weak self] resp in
            guard let self else { return }
            guard resp["success"] as? Bool == true else {
                self.events.output("Adapter failed to initialise: \(resp["message"] ?? "")", .error)
                self.events.terminated(); return
            }
            self.client.request("launch", self.launch) { [weak self] r in
                if r["success"] as? Bool != true {
                    self?.events.output("Launch failed: \((r["message"] as? String) ?? "")", .error)
                    self?.events.terminated()
                }
            }
        }
    }

    private func event(_ name: String, _ body: JSON) {
        switch name {
        case "initialized":
            events.ready()
            client.request("setExceptionBreakpoints", ["filters": []])
            client.request("configurationDone")
        case "stopped":
            threadId = body["threadId"] as? Int ?? threadId
            events.stopped(body["reason"] as? String ?? "paused")
        case "continued":
            events.continued()
        case "output":
            guard let text = body["output"] as? String, body["category"] as? String != "telemetry" else { return }
            let cat = body["category"] as? String ?? "console"
            events.output(text, cat == "stderr" ? .stderr : cat == "stdout" ? .stdout : .info)
        case "exited":
            if let code = body["exitCode"] as? Int { events.output("Process exited with code \(code)", .info) }
        case "terminated":
            events.terminated()
        default: break
        }
    }

    func setBreakpoints(path: String, lines: [(line: Int, condition: String)]) {
        client.request("setBreakpoints", ["source": ["path": path, "name": (path as NSString).lastPathComponent],
                                          "breakpoints": lines.map { l -> JSON in l.condition.isEmpty ? ["line": l.line] : ["line": l.line, "condition": l.condition] },
                                          "lines": lines.map(\.line)])
    }

    func resume() { client.request("continue", ["threadId": threadId]) }
    func stepOver() { client.request("next", ["threadId": threadId]) }
    func stepInto() { client.request("stepIn", ["threadId": threadId]) }
    func stepOut() { client.request("stepOut", ["threadId": threadId]) }
    func pause() { client.request("pause", ["threadId": threadId]) }

    func stop() {
        client.request("disconnect", ["terminateDebuggee": true]) { [weak self] _ in self?.client.kill() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.client.kill() }
    }

    func stackTrace(_ done: @escaping ([StackFrame]) -> Void) {
        client.request("stackTrace", ["threadId": threadId, "startFrame": 0, "levels": 60]) { r in
            let list = ((r["body"] as? JSON)?["stackFrames"] as? [JSON]) ?? []
            done(list.map { f in
                let path = (f["source"] as? JSON)?["path"] as? String
                return StackFrame(id: f["id"] as? Int ?? 0, name: f["name"] as? String ?? "?", url: path.map { URL(fileURLWithPath: $0).standardizedFileURL }, line: f["line"] as? Int ?? 0)
            })
        }
    }

    func scopes(frame: StackFrame, _ done: @escaping ([VarNode]) -> Void) {
        client.request("scopes", ["frameId": frame.id]) { r in
            let list = ((r["body"] as? JSON)?["scopes"] as? [JSON]) ?? []
            done(list.map { VarNode(name: $0["name"] as? String ?? "", value: "", type: "", reference: $0["variablesReference"] as? Int ?? 0) })
        }
    }

    func variables(reference: Int, _ done: @escaping ([VarNode]) -> Void) {
        client.request("variables", ["variablesReference": reference]) { r in
            let vars = ((r["body"] as? JSON)?["variables"] as? [JSON]) ?? []
            done(vars.prefix(500).map {
                VarNode(name: $0["name"] as? String ?? "", value: $0["value"] as? String ?? "", type: $0["type"] as? String ?? "",
                        reference: $0["variablesReference"] as? Int ?? 0)
            })
        }
    }

    func evaluate(_ expression: String, frame: StackFrame?, _ done: @escaping (String, Bool) -> Void) {
        var args: JSON = ["expression": expression, "context": "repl"]
        if let frame { args["frameId"] = frame.id }
        client.request("evaluate", args) { r in
            if r["success"] as? Bool == true { done(((r["body"] as? JSON)?["result"] as? String) ?? "", true) }
            else { done((r["message"] as? String) ?? "error", false) }
        }
    }
}
