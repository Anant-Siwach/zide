import AppKit
import SwiftUI

// MARK: - Remote folders over SSH. Zide keeps a local copy of the remote folder (rsync over SSH): opening downloads it,
// every save uploads that file straight away, and changes on the server are pulled every 20 seconds (files with
// unsaved edits are left alone). Terminals and run configurations execute on the server. Uses your SSH keys/agent.

struct RemoteSpec: Codable, Hashable {
    var host: String           // an ~/.ssh/config alias or user@host
    var path: String           // folder on the server
    var title: String { "\(host):\(path)" }
}

enum Remote {
    /// The ssh command (tests substitute a stand-in that runs commands locally).
    static var ssh: String { ProcessInfo.processInfo.environment["ZIDE_SSH"] ?? "/usr/bin/ssh" }
    static let sshOptions = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15"]
    static let excludes = [".git/", "node_modules/", ".venv/", "venv/", "__pycache__/", "target/", ".build/", "build/", "dist/", ".next/", ".DS_Store"]

    static var mirrorsFolder: URL {
        let base = ProcessInfo.processInfo.environment["ZIDE_TESTDIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Zide")
        return base.appendingPathComponent("Remote", isDirectory: true)
    }
    static func mirror(for s: RemoteSpec) -> URL {
        var h: UInt64 = 1469598103934665603
        for c in s.title.utf8 { h = (h ^ UInt64(c)) &* 1099511628211 }
        let name = (s.path as NSString).lastPathComponent.isEmpty ? "home" : (s.path as NSString).lastPathComponent
        return mirrorsFolder.appendingPathComponent("\(s.host.replacingOccurrences(of: "/", with: "_"))-\(String(h, radix: 36))", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    /// Registry of mirrors → remote, so a reopened mirror stays connected.
    static var registryURL: URL { mirrorsFolder.appendingPathComponent("remotes.json") }
    static func registry() -> [String: RemoteSpec] { (try? JSONDecoder().decode([String: RemoteSpec].self, from: Data(contentsOf: registryURL))) ?? [:] }
    static func spec(for root: URL) -> RemoteSpec? { registry()[root.standardizedFileURL.path] }
    static func register(_ s: RemoteSpec, mirror: URL) {
        var r = registry(); r[mirror.standardizedFileURL.path] = s
        try? FileManager.default.createDirectory(at: mirrorsFolder, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(r) { try? d.write(to: registryURL, options: .atomic) }
    }

    /// Host aliases from ~/.ssh/config, for the picker.
    static func configuredHosts() -> [String] {
        guard let t = try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config"), encoding: .utf8) else { return [] }
        return t.split(separator: "\n").compactMap { l in
            let p = l.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard p.count == 2, p[0].lowercased() == "host" else { return nil }
            return p[1].split(separator: " ").first.map(String.init)
        }.filter { !$0.contains("*") }
    }

    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static var rsh: String { ([ssh] + sshOptions).map { $0.contains(" ") ? q($0) : $0 }.joined(separator: " ") }

    /// Runs rsync; returns (ok, message).
    static func rsync(_ args: [String]) -> (Bool, String) {
        let r = Shell.run("rsync", ["-az", "-e", rsh] + args)
        return (r.ok, r.ok ? r.out : (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func download(_ s: RemoteSpec, to mirror: URL, skipping: [String] = []) -> (Bool, String) {
        try? FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        let ex = (excludes + skipping).flatMap { ["--exclude", $0] }
        return rsync(ex + ["\(s.host):\(s.path.hasSuffix("/") ? s.path : s.path + "/")", mirror.path + "/"])
    }

    static func upload(_ s: RemoteSpec, mirror: URL, file: URL) -> (Bool, String) {
        let rel = String(file.standardizedFileURL.path.dropFirst(mirror.standardizedFileURL.path.count + 1))
        let base = s.path.hasSuffix("/") ? String(s.path.dropLast()) : s.path
        let dest = base + "/" + rel
        // Make the folder first, then copy the file to its exact path. (macOS's openrsync ignores the "/./" marker of
        // --relative, so that trick would recreate the whole local path on the server.)
        let dir = (dest as NSString).deletingLastPathComponent
        if rel.contains("/") {
            let mk = Shell.run(ssh, sshOptions + [s.host, "mkdir -p \(q(dir))"])
            if !mk.ok { return (false, mk.err.isEmpty ? "mkdir failed" : mk.err) }
        }
        return rsync([file.path, "\(s.host):\(dest)"])
    }

    static func uploadAll(_ s: RemoteSpec, mirror: URL) -> (Bool, String) {
        rsync(excludes.flatMap { ["--exclude", $0] } + [mirror.path + "/", "\(s.host):\(s.path.hasSuffix("/") ? s.path : s.path + "/")"])
    }

    /// A shell command that runs `command` in the remote folder (for terminals and run configurations).
    static func remoteShell(_ s: RemoteSpec, command: String?) -> String {
        let inner = "cd \(q(s.path)) && " + (command ?? "exec ${SHELL:-/bin/sh} -l")
        // Interactive: no BatchMode, so a passphrase prompt can appear in the terminal.
        return ([ssh, "-t", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15"]).map { $0.contains(" ") ? q($0) : $0 }.joined(separator: " ") + " \(q(s.host)) \(q(inner))"
    }
}

@MainActor
final class RemoteSession: ObservableObject {
    let spec: RemoteSpec
    unowned let workspace: Workspace
    @Published var status = ""
    @Published var lastSync: Date?
    @Published var syncing = false
    private var timer: Timer?

    init(spec: RemoteSpec, workspace: Workspace) {
        self.spec = spec; self.workspace = workspace
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in MainActor.assumeIsolated { if NSApp.isActive { self?.pull() } } }
    }
    deinit { timer?.invalidate() }

    /// Brings in changes made on the server (never overwriting files you are editing).
    func pull() {
        guard !syncing else { return }
        syncing = true
        let dirty = workspace.documents.filter(\.isDirty).map { "/" + workspace.relative($0.url) }
        let s = spec, root = workspace.root
        Task {
            let (ok, msg) = await Task.detached { Remote.download(s, to: root, skipping: dirty) }.value
            syncing = false
            if ok { lastSync = Date(); status = "" } else { status = msg }
            if ok { for d in workspace.documents where !d.isDirty { d.reloadIfChangedOnDisk() } }
        }
    }

    /// Called after a file is saved: uploads it.
    func saved(_ url: URL) {
        let s = spec, root = workspace.root
        syncing = true
        Task {
            let (ok, msg) = await Task.detached { Remote.upload(s, mirror: root, file: url) }.value
            syncing = false
            if ok { lastSync = Date(); status = "" } else { status = msg; workspace.flash("Upload to \(s.host) failed: \(msg.prefix(120))") }
        }
    }

    func pushAll() {
        let s = spec, root = workspace.root
        syncing = true
        Task {
            let (ok, msg) = await Task.detached { Remote.uploadAll(s, mirror: root) }.value
            syncing = false
            workspace.flash(ok ? "Uploaded everything to \(s.host)" : "Upload failed: \(msg.prefix(120))")
            if ok { lastSync = Date() }
        }
    }

    func terminal() {
        workspace.terminals.newTerminal(command: Remote.remoteShell(spec, command: nil), title: spec.host)
    }
}

// MARK: - Connect dialog

enum RemoteConnect {
    @MainActor static func show() {
        let a = NSAlert()
        a.messageText = "Open Remote Folder (SSH)"
        a.informativeText = "Zide copies the folder to this Mac, uploads each file when you save, and runs terminals and run configurations on the server. It uses your SSH keys (passwords can't be typed here — set up a key with ssh-copy-id)."
        let host = NSComboBox(frame: NSRect(x: 0, y: 30, width: 360, height: 26))
        host.addItems(withObjectValues: Remote.configuredHosts())
        host.placeholderString = "user@server or an ~/.ssh/config host"
        host.stringValue = UserDefaults.standard.string(forKey: "remoteLastHost") ?? ""
        let path = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        path.placeholderString = "Folder on the server, e.g. ~/projects/app"
        path.stringValue = UserDefaults.standard.string(forKey: "remoteLastPath") ?? ""
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 58)); box.addSubview(host); box.addSubview(path)
        a.accessoryView = box
        a.addButton(withTitle: "Open"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let spec = RemoteSpec(host: host.stringValue.trimmingCharacters(in: .whitespaces), path: path.stringValue.trimmingCharacters(in: .whitespaces))
        guard !spec.host.isEmpty, !spec.path.isEmpty else { return }
        UserDefaults.standard.set(spec.host, forKey: "remoteLastHost"); UserDefaults.standard.set(spec.path, forKey: "remoteLastPath")
        open(spec)
    }

    @MainActor static func open(_ spec: RemoteSpec, done: ((Bool, String) -> Void)? = nil) {
        let mirror = Remote.mirror(for: spec)
        let progress = NSAlert(); progress.messageText = "Connecting to \(spec.host)…"; progress.informativeText = "Copying \(spec.path)"
        Task {
            let (ok, msg) = await Task.detached { Remote.download(spec, to: mirror) }.value
            guard ok else {
                if let done { done(false, msg); return }
                let e = NSAlert(); e.messageText = "Couldn't open \(spec.title)"; e.informativeText = msg.isEmpty ? "rsync failed." : String(msg.prefix(600)); e.runModal()
                return
            }
            Remote.register(spec, mirror: mirror)
            _ = AppDelegate.shared.openProject(mirror)
            done?(true, "")
        }
    }
}
