import AppKit

/// The user's login-shell environment. Apps launched from Finder get a minimal PATH, so tools
/// installed with nvm, Homebrew, cargo, etc. would be invisible without this.
enum Env {
    private static let lock = NSLock()
    private static var cached: [String: String]?

    static var environment: [String: String] {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        var env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-i", "-c", "printf '__ZIDE__%s__ZIDE__' \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let deadline = Date().addingTimeInterval(4)
            while p.isRunning && Date() < deadline { usleep(20_000) }
            if p.isRunning { p.terminate() }
            let s = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
            if let r = s.range(of: "__ZIDE__"), let e = s.range(of: "__ZIDE__", range: r.upperBound..<s.endIndex) {
                env["PATH"] = String(s[r.upperBound..<e.lowerBound])
            }
        }
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.cargo/bin", "\(NSHomeDirectory())/go/bin", "\(NSHomeDirectory())/.local/bin"]
        var parts = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for e in extra where !parts.contains(e) { parts.append(e) }
        env["PATH"] = parts.joined(separator: ":")
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env.removeValue(forKey: "__CFBundleIdentifier")
        cached = env
        return env
    }

    static var path: [String] { (environment["PATH"] ?? "").split(separator: ":").map(String.init) }

    /// Resolves a command name to an executable path using the login PATH.
    static func which(_ name: String) -> String? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        for dir in path {
            let p = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Prewarms the environment off the main thread at launch.
    static func warmUp() { DispatchQueue.global(qos: .userInitiated).async { _ = environment } }
}

enum Shell {
    struct Result { let status: Int32; let out: String; let err: String; var ok: Bool { status == 0 } }

    /// Runs a tool synchronously (call off the main thread for anything slow).
    @discardableResult
    static func run(_ tool: String, _ args: [String], cwd: URL? = nil, input: String? = nil) -> Result {
        let p = Process()
        guard let exe = Env.which(tool) else { return Result(status: 127, out: "", err: "\(tool) not found") }
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = Env.environment
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        if let input {
            let inPipe = Pipe()
            p.standardInput = inPipe
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        } else {
            p.standardInput = FileHandle.nullDevice
        }
        do { try p.run() } catch { return Result(status: 127, out: "", err: error.localizedDescription) }
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        errData = err.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, out: String(decoding: outData, as: UTF8.self), err: String(decoding: errData, as: UTF8.self))
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
