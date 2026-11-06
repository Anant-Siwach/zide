import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Replace in Files: preview before applying

struct ReplacePreviewItem: Identifiable {
    let id = UUID()
    let file: URL
    let line: Int
    let before: String
    let after: String
    var include = true
    let edit: (NSRange, String)
}

@MainActor
final class ReplacePreviewModel: ObservableObject {
    @Published var items: [ReplacePreviewItem]
    let title: String
    var done: ((Bool) -> Void)?
    init(items: [ReplacePreviewItem], title: String) { self.items = items; self.title = title }
    var included: Int { items.filter(\.include).count }

    /// Shows the preview modally; returns the edits the user kept, or nil if cancelled.
    static func run(items: [ReplacePreviewItem], title: String) -> [ReplacePreviewItem]? {
        let model = ReplacePreviewModel(items: items, title: title)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Replace Preview"
        var result: [ReplacePreviewItem]?
        model.done = { ok in
            if ok { result = model.items.filter(\.include) }
            NSApp.stopModal()
        }
        w.contentView = NSHostingView(rootView: ReplacePreviewView(model: model))
        w.center()
        NSApp.runModal(for: w)
        w.orderOut(nil)
        return result
    }
}

struct ReplacePreviewView: View {
    @ObservedObject var model: ReplacePreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.title).font(.headline).padding(14)
            Divider()
            List {
                ForEach(Dictionary(grouping: model.items.indices, by: { model.items[$0].file }).sorted { $0.key.path < $1.key.path }, id: \.key) { file, idxs in
                    Section {
                        ForEach(idxs, id: \.self) { i in
                            HStack(alignment: .top, spacing: 8) {
                                Toggle("", isOn: $model.items[i].include).labelsHidden()
                                Text("\(model.items[i].line)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.items[i].before).strikethrough().foregroundStyle(.red.opacity(0.85))
                                    Text(model.items[i].after).foregroundStyle(.green)
                                }
                                .font(.system(size: 12, design: .monospaced)).lineLimit(2)
                            }
                        }
                    } header: {
                        HStack {
                            Text(file.lastPathComponent).font(.subheadline.bold())
                            Spacer()
                            Button("All") { idxs.forEach { model.items[$0].include = true } }.buttonStyle(.borderless)
                            Button("None") { idxs.forEach { model.items[$0].include = false } }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text("\(model.included) of \(model.items.count) replacements selected").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.done?(false) }.keyboardShortcut(.cancelAction)
                Button("Replace \(model.included)") { model.done?(true) }.keyboardShortcut(.defaultAction).disabled(model.included == 0)
            }
            .padding(12)
        }
        .frame(minWidth: 640, minHeight: 360)
    }
}

// MARK: - Compare with clipboard / another file

@MainActor
enum Compare {
    static func show(_ ws: Workspace, left: URL, rightText: String?, right: URL?, title: String) {
        var rightURL = right
        if let text = rightText {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("zide-clipboard-\(UUID().uuidString.prefix(6)).txt")
            try? text.write(to: tmp, atomically: true, encoding: .utf8)
            rightURL = tmp
        }
        guard let r = rightURL else { return }
        // Unsaved edits count: compare what's in the editor, not what's on disk.
        let leftTmp = FileManager.default.temporaryDirectory.appendingPathComponent("zide-\(left.lastPathComponent)")
        if let doc = ws.documents.first(where: { $0.url == left }) { try? doc.storage.string.write(to: leftTmp, atomically: true, encoding: .utf8) }
        let leftPath = ws.documents.contains { $0.url == left } ? leftTmp.path : left.path
        Task.detached {
            let res = Shell.run("git", ["diff", "--no-index", "--no-color", "-U3", "--", leftPath, r.path])
            await MainActor.run {
                ws.git.diffPath = title
                ws.git.diffText = res.out.isEmpty ? (res.err.isEmpty ? "(no differences)" : res.err) : res.out
                DiffWindow.show(git: ws.git)
            }
        }
    }
}

// MARK: - Quick note from anywhere (global hotkey ⌃⌥N)

@MainActor
enum QuickNote {
    private static var ref: EventHotKeyRef?
    private(set) static var registered = false

    /// Registers ⌃⌥N system-wide (works while Zide is running, including in the background).
    static func register() {
        guard ref == nil, Prefs.shared.quickNoteHotkey else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { QuickNote.open() } }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x5A494445), id: 1)   // 'ZIDE'
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
        registered = status == noErr
    }

    static func unregister() { if let r = ref { UnregisterEventHotKey(r); ref = nil } }

    /// A new Markdown note in the Notes folder, in a light single-file window.
    static func open() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Zide Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"
        var url = dir.appendingPathComponent("Note \(f.string(from: Date())).md")
        var k = 2
        while FileManager.default.fileExists(atPath: url.path) { url = dir.appendingPathComponent("Note \(f.string(from: Date())) \(k).md"); k += 1 }
        FileManager.default.createFile(atPath: url.path, contents: Data())
        AppDelegate.shared.openPath(url)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Install a missing language server, then start it

extension Workspace {
    func installServer(_ spec: ServerSpec, for language: Language) {
        terminals.newTerminal(command: spec.install, title: "Install \(spec.command)")
        bottomTab = .terminal; bottomVisible = true
        flash("Installing \(spec.command)… Zide starts it when it's ready")
        let lsp = self.lsp
        Task { @MainActor [weak self] in
            for _ in 0..<150 {            // up to 5 minutes
                try? await Task.sleep(for: .seconds(2))
                if Env.which(spec.command) != nil {
                    lsp.restart(language)
                    self?.flash("\(spec.command) installed — \(language.name) features are on")
                    return
                }
            }
        }
    }
}

// MARK: - Test detection (▶ in the gutter)

struct TestTarget { let name: String; let command: String }

@MainActor
enum TestFinder {
    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Test functions by 1-based line, with the command that runs just that test.
    static func find(_ doc: EditorDocument, root: URL) -> [Int: TestTarget] {
        guard doc.storage.length < 400_000 else { return [:] }
        let text = doc.storage.string
        let rel = doc.url.path.hasPrefix(root.path + "/") ? String(doc.url.path.dropFirst(root.path.count + 1)) : doc.url.path
        let lines = text.components(separatedBy: "\n")
        var out: [Int: TestTarget] = [:]
        func add(_ i: Int, _ name: String, _ cmd: String) { out[i + 1] = TestTarget(name: name, command: cmd) }
        switch doc.language.id {
        case "swift":
            for (i, l) in lines.enumerated() {
                if let m = l.firstMatch(of: #/func\s+(test\w*)\s*\(\s*\)/#), l.contains("func") { add(i, String(m.1), "swift test --filter \(q(String(m.1)))") }
                else if l.trimmingCharacters(in: .whitespaces).hasPrefix("@Test"), i + 1 < lines.count, let m = (lines[i + 1] + " " + l).firstMatch(of: #/func\s+(\w+)/#) {
                    add(i, String(m.1), "swift test --filter \(q(String(m.1)))")
                }
            }
        case "python":
            guard doc.url.lastPathComponent.hasPrefix("test") || doc.url.lastPathComponent.hasSuffix("_test.py") else { break }
            for (i, l) in lines.enumerated() { if let m = l.firstMatch(of: #/^\s*(?:async\s+)?def\s+(test\w*)\s*\(/#) { add(i, String(m.1), "python3 -m pytest \(q(rel)) -k \(q(String(m.1))) -q") } }
        case "go":
            guard doc.url.lastPathComponent.hasSuffix("_test.go") else { break }
            let dir = (rel as NSString).deletingLastPathComponent
            for (i, l) in lines.enumerated() { if let m = l.firstMatch(of: #/^func\s+(Test\w*)\s*\(\s*\w+\s+\*testing\.T\s*\)/#) { add(i, String(m.1), "go test -run \(q("^\(m.1)$")) ./\(dir.isEmpty ? "" : dir)") } }
        case "rust":
            for (i, l) in lines.enumerated() where l.trimmingCharacters(in: .whitespaces).hasPrefix("#[test]") || l.contains("#[tokio::test]") {
                if let j = (i + 1..<min(lines.count, i + 4)).first(where: { lines[$0].contains("fn ") }), let m = lines[j].firstMatch(of: #/fn\s+(\w+)/#) { add(j, String(m.1), "cargo test \(q(String(m.1)))") }
            }
        case "javascript", "typescript", "javascriptreact", "typescriptreact":
            let name = doc.url.lastPathComponent
            guard name.contains(".test.") || name.contains(".spec.") || rel.contains("__tests__") else { break }
            let pkg = (try? String(contentsOf: root.appendingPathComponent("package.json"), encoding: .utf8)) ?? ""
            for (i, l) in lines.enumerated() {
                guard let m = l.firstMatch(of: #/^\s*(?:test|it|describe)(?:\.only)?\s*\(\s*['"`](.+?)['"`]/#) else { continue }
                let t = String(m.1)
                let cmd = pkg.contains("vitest") ? "npx vitest run \(q(rel)) -t \(q(t))" : pkg.contains("jest") ? "npx jest \(q(rel)) -t \(q(t))" : "node --test --test-name-pattern=\(q(t)) \(q(rel))"
                add(i, t, cmd)
            }
        default: break
        }
        return out
    }
}
