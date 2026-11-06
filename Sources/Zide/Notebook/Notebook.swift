import AppKit
import SwiftUI

// MARK: - Jupyter notebooks (.ipynb): cells with outputs and charts, run with Python — no Jupyter install needed.
// A small driver keeps one Python process per notebook (variables persist between cells), captures printed output,
// the value of the last line, errors, and matplotlib figures as images. Saved as standard nbformat 4.

struct NBOutput: Identifiable {
    let id = UUID()
    var raw: [String: Any]
    var type: String { raw["output_type"] as? String ?? "" }
    var text: String {
        switch type {
        case "stream": return NBCell.joined(raw["text"])
        case "error": return ((raw["traceback"] as? [String]) ?? ["\(raw["ename"] ?? ""): \(raw["evalue"] ?? "")"]).joined(separator: "\n").replacingOccurrences(of: #"\u{1B}\[[0-9;]*m"#, with: "", options: .regularExpression)
        default: return NBCell.joined((raw["data"] as? [String: Any])?["text/plain"])
        }
    }
    var image: NSImage? {
        guard let d = raw["data"] as? [String: Any], let b = d["image/png"] as? String ?? (d["image/png"] as? [String])?.joined(),
              let data = Data(base64Encoded: b.replacingOccurrences(of: "\n", with: "")) else { return nil }
        return NSImage(data: data)
    }
    var isError: Bool { type == "error" || (type == "stream" && raw["name"] as? String == "stderr") }
}

struct NBCell: Identifiable {
    let id = UUID()
    var type: String              // code, markdown, raw
    var source: String
    var outputs: [NBOutput] = []
    var count: Int?
    var metadata: [String: Any] = [:]
    var running = false
    var editing = false

    static func joined(_ v: Any?) -> String { (v as? String) ?? ((v as? [String])?.joined() ?? "") }
}

@MainActor
final class PythonKernel {
    private var process: Process?
    private var input: FileHandle?
    private var buffer = ""
    private var waiting: [String: ([String: Any]) -> Void] = [:]
    private var queue: [() -> Void] = []
    let python: String
    let cwd: URL
    var onDied: (() -> Void)?

    init(python: String, cwd: URL) { self.python = python; self.cwd = cwd }

    static let driver = #"""
import sys, json, ast, io, traceback, base64, contextlib, builtins
_out = sys.__stdout__
ns = {'__name__': '__main__'}
count = 0
try:
    import matplotlib; matplotlib.use('Agg')
except Exception:
    pass
def _figs():
    res = []
    try:
        import matplotlib.pyplot as plt
        for n in plt.get_fignums():
            b = io.BytesIO(); plt.figure(n).savefig(b, format='png', bbox_inches='tight', dpi=110)
            res.append({'output_type': 'display_data', 'data': {'image/png': base64.b64encode(b.getvalue()).decode(), 'text/plain': '<Figure>'}, 'metadata': {}})
        plt.close('all')
    except Exception:
        pass
    return res
def _no_input(*a, **k):
    raise RuntimeError('input() is not available in notebook cells')
builtins.input = _no_input
for line in sys.stdin:
    try:
        req = json.loads(line)
    except Exception:
        continue
    count += 1
    so, se = io.StringIO(), io.StringIO()
    result, err = None, None
    try:
        with contextlib.redirect_stdout(so), contextlib.redirect_stderr(se):
            tree = ast.parse(req['code'], '<cell>', 'exec')
            last = None
            if tree.body and isinstance(tree.body[-1], ast.Expr):
                last = ast.Expression(tree.body.pop().value)
            exec(compile(tree, '<cell>', 'exec'), ns)
            if last is not None:
                result = eval(compile(last, '<cell>', 'eval'), ns)
                if result is not None: ns['_'] = result
    except KeyboardInterrupt:
        err = {'output_type': 'error', 'ename': 'KeyboardInterrupt', 'evalue': '', 'traceback': ['KeyboardInterrupt: interrupted']}
    except BaseException as e:
        tb = traceback.format_exception(type(e), e, e.__traceback__)
        tb = [l for l in tb if 'File "<string>"' not in l]
        err = {'output_type': 'error', 'ename': type(e).__name__, 'evalue': str(e), 'traceback': [''.join(tb)]}
    outs = []
    if so.getvalue(): outs.append({'output_type': 'stream', 'name': 'stdout', 'text': so.getvalue()})
    if se.getvalue(): outs.append({'output_type': 'stream', 'name': 'stderr', 'text': se.getvalue()})
    outs += _figs()
    if result is not None and err is None:
        data = {'text/plain': repr(result)}
        try:
            if hasattr(result, '_repr_png_'):
                p = result._repr_png_()
                if p: data['image/png'] = base64.b64encode(p).decode()
        except Exception:
            pass
        outs.append({'output_type': 'execute_result', 'execution_count': count, 'data': data, 'metadata': {}})
    if err: outs.append(err)
    _out.write('\x1eZIDE' + json.dumps({'id': req['id'], 'count': count, 'outputs': outs}) + '\n'); _out.flush()
"""#

    func start() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-u", "-c", Self.driver]
        p.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"; env["MPLBACKEND"] = "Agg"
        p.environment = env
        let i = Pipe(), o = Pipe()
        p.standardInput = i; p.standardOutput = o; p.standardError = o
        Self.attach(p, output: o) { [weak self] s in self?.received(s) } died: { [weak self] in self?.died() }
        guard (try? p.run()) != nil else { return false }
        process = p; input = i.fileHandleForWriting
        return true
    }

    /// Handlers built outside the main actor: Foundation calls them on background threads.
    nonisolated private static func attach(_ p: Process, output o: Pipe, received: @escaping @MainActor (String) -> Void, died: @escaping @MainActor () -> Void) {
        o.fileHandleForReading.readabilityHandler = { h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            guard !s.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { received(s) } }
        }
        p.terminationHandler = { _ in DispatchQueue.main.async { MainActor.assumeIsolated { died() } } }
    }

    private func died() {
        for (_, c) in waiting { c(["outputs": [["output_type": "error", "ename": "KernelDied", "evalue": "Python stopped", "traceback": ["Python stopped (crashed or was interrupted). Run the cell again to restart it."]]]]) }
        waiting = [:]; process = nil
        onDied?()
    }

    private func received(_ s: String) {
        buffer += s
        while let nl = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<nl]); buffer = String(buffer[buffer.index(after: nl)...])
            guard let r = line.range(of: "\u{1E}ZIDE") else { continue }   // other lines: stray output of child processes
            guard let o = try? JSONSerialization.jsonObject(with: Data(line[r.upperBound...].utf8)) as? [String: Any], let id = o["id"] as? String else { continue }
            waiting.removeValue(forKey: id)?(o)
        }
    }

    /// Runs code; `done` gets the execution count and the outputs (on the main thread).
    func execute(_ code: String, done: @escaping (Int?, [[String: Any]]) -> Void) {
        if process == nil, !start() { done(nil, [["output_type": "error", "ename": "NoPython", "evalue": "", "traceback": ["Couldn't start \(python)."]]]); return }
        let id = UUID().uuidString
        waiting[id] = { o in done(o["count"] as? Int, o["outputs"] as? [[String: Any]] ?? []) }
        let line = (try? JSONSerialization.data(withJSONObject: ["id": id, "code": code])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        do { try input?.write(contentsOf: Data((line + "\n").utf8)) } catch {
            waiting.removeValue(forKey: id)
            process = nil
            done(nil, [["output_type": "error", "ename": "KernelDied", "evalue": "", "traceback": ["Python isn't running. Run the cell again to restart it."]]])
        }
    }

    func interrupt() { if let p = process { kill(p.processIdentifier, SIGINT) } }
    func stop() { process?.terminate(); process = nil }
    var running: Bool { process != nil }
}

@MainActor
final class NotebookModel: ObservableObject {
    let doc: EditorDocument
    unowned let workspace: Workspace
    @Published var cells: [NBCell] = []
    @Published var error: String?
    @Published var kernelBusy = false
    private var meta: [String: Any] = [:]
    private var nbformat = (4, 5)
    private var saveTimer: Timer?
    lazy var kernel: PythonKernel = PythonKernel(python: Self.python(for: workspace.root, doc.url), cwd: doc.url.deletingLastPathComponent())

    init(workspace: Workspace, doc: EditorDocument) {
        self.workspace = workspace; self.doc = doc
        load()
    }

    /// The project's virtualenv if there is one, else python3.
    static func python(for root: URL, _ file: URL) -> String {
        for dir in [file.deletingLastPathComponent(), root] {
            for v in [".venv", "venv", "env"] {
                let p = dir.appendingPathComponent(v).appendingPathComponent("bin/python")
                if FileManager.default.isExecutableFile(atPath: p.path) { return p.path }
            }
        }
        return Env.which("python3") ?? "/usr/bin/python3"
    }

    func load() {
        let text = doc.text
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { cells = [NBCell(type: "code", source: "")]; return }
        guard let o = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { error = "This notebook isn't valid JSON. View it as text to fix it."; return }
        meta = o["metadata"] as? [String: Any] ?? [:]
        nbformat = (o["nbformat"] as? Int ?? 4, o["nbformat_minor"] as? Int ?? 5)
        cells = (o["cells"] as? [[String: Any]] ?? []).map { c in
            NBCell(type: c["cell_type"] as? String ?? "code", source: NBCell.joined(c["source"]),
                   outputs: (c["outputs"] as? [[String: Any]] ?? []).map { NBOutput(raw: $0) }, count: c["execution_count"] as? Int,
                   metadata: c["metadata"] as? [String: Any] ?? [:])
        }
        if cells.isEmpty { cells = [NBCell(type: "code", source: "")] }
    }

    /// nbformat 4 JSON: sources and texts as line arrays, like Jupyter writes them.
    func serialize() -> String {
        func lines(_ s: String) -> [String] {
            guard !s.isEmpty else { return [] }
            var out = s.components(separatedBy: "\n").map { $0 + "\n" }
            out[out.count - 1].removeLast()
            if out.last == "" { out.removeLast() }
            return out
        }
        let cs: [[String: Any]] = cells.map { c in
            var d: [String: Any] = ["cell_type": c.type, "metadata": c.metadata, "source": lines(c.source)]
            if c.type == "code" {
                d["execution_count"] = c.count ?? NSNull()
                d["outputs"] = c.outputs.map { o -> [String: Any] in
                    var r = o.raw
                    if o.type == "stream", let t = r["text"] as? String { r["text"] = lines(t) }
                    return r
                }
            }
            return d
        }
        var m = meta
        if m["kernelspec"] == nil { m["kernelspec"] = ["display_name": "Python 3", "language": "python", "name": "python3"] }
        if m["language_info"] == nil { m["language_info"] = ["name": "python"] }
        let o: [String: Any] = ["cells": cs, "metadata": m, "nbformat": nbformat.0, "nbformat_minor": nbformat.1]
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return doc.text }
        return String(decoding: d, as: UTF8.self) + "\n"
    }

    /// Writes the cells back into the document (unsaved until ⌘S, like any edit).
    func changed() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.flush() } }
    }
    func flush() {
        saveTimer?.invalidate(); saveTimer = nil
        let json = serialize()
        guard json != doc.text else { return }
        doc.storage.replaceCharacters(in: NSRange(location: 0, length: doc.storage.length), with: json)
        doc.markEdited()
    }

    func run(_ id: UUID, thenNext: Bool = false) {
        guard let i = cells.firstIndex(where: { $0.id == id }) else { return }
        if cells[i].type != "code" { cells[i].editing = false; if thenNext { advance(from: i) }; return }
        cells[i].running = true; kernelBusy = true
        kernel.execute(cells[i].source) { [weak self] count, outputs in
            guard let self else { return }
            if let j = self.cells.firstIndex(where: { $0.id == id }) {
                self.cells[j].outputs = outputs.map { NBOutput(raw: $0) }
                self.cells[j].count = count
                self.cells[j].running = false
            }
            self.kernelBusy = self.cells.contains { $0.running }
            self.changed()
            if thenNext { self.advance(from: i) }
        }
    }
    private func advance(from i: Int) { if i + 1 >= cells.count { add(after: cells[i].id, type: "code") } }

    func runAll() {
        Task {
            for c in cells where c.type == "code" {
                run(c.id)
                while cells.first(where: { $0.id == c.id })?.running == true { try? await Task.sleep(for: .milliseconds(50)) }
                if cells.first(where: { $0.id == c.id })?.outputs.contains(where: { $0.type == "error" }) == true { break }
            }
        }
    }
    func add(after id: UUID?, type: String) {
        let c = NBCell(type: type, source: "", editing: true)
        if let id, let i = cells.firstIndex(where: { $0.id == id }) { cells.insert(c, at: i + 1) } else { cells.append(c) }
        changed()
    }
    func delete(_ id: UUID) { cells.removeAll { $0.id == id }; if cells.isEmpty { cells = [NBCell(type: "code", source: "")] }; changed() }
    func move(_ id: UUID, by d: Int) {
        guard let i = cells.firstIndex(where: { $0.id == id }), cells.indices.contains(i + d) else { return }
        cells.swapAt(i, i + d); changed()
    }
    func clearOutputs() { for i in cells.indices { cells[i].outputs = []; cells[i].count = nil }; changed() }
    func restart() { kernel.stop(); for i in cells.indices { cells[i].running = false }; kernelBusy = false }
}

struct NotebookView: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var doc: EditorDocument
    @StateObject private var model: NotebookModel
    @ObservedObject var theme = ThemeObserver.shared

    init(ws: Workspace, doc: EditorDocument) {
        self.ws = ws; self.doc = doc
        _model = StateObject(wrappedValue: NotebookModel(workspace: ws, doc: doc))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { model.runAll() } label: { Label("Run All", systemImage: "forward.fill") }
                Button { model.kernel.interrupt() } label: { Label("Interrupt", systemImage: "stop.fill") }.disabled(!model.kernelBusy)
                Button { model.restart() } label: { Label("Restart", systemImage: "arrow.clockwise") }
                Button { model.clearOutputs() } label: { Label("Clear Outputs", systemImage: "eraser") }
                Spacer()
                Text(model.kernel.python.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Circle().fill(model.kernelBusy ? Color.orange : model.kernel.running ? Color.green : Color.gray).frame(width: 8, height: 8)
                Button("View as JSON") { model.flush(); ws.notebookAsText = true }.controlSize(.small)
            }
            .labelStyle(.titleAndIcon).controlSize(.small)
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            if let e = model.error {
                Text(e).foregroundStyle(.orange).padding()
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach($model.cells) { $cell in CellView(cell: $cell, model: model) }
                        HStack {
                            Button("+ Code") { model.add(after: nil, type: "code") }
                            Button("+ Markdown") { model.add(after: nil, type: "markdown") }
                        }.controlSize(.small).padding(.leading, 50)
                    }
                    .padding(14)
                    .frame(maxWidth: 1000, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(theme.palette.background.swiftUI)
        .onDisappear { model.flush() }
        .onReceive(NotificationCenter.default.publisher(for: .zideWillSave)) { _ in model.flush() }
    }
}

private struct CellView: View {
    @Binding var cell: NBCell
    @ObservedObject var model: NotebookModel
    @ObservedObject var theme = ThemeObserver.shared
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 4) {
                if cell.type == "code" {
                    Button { model.run(cell.id) } label: {
                        if cell.running { ProgressView().controlSize(.mini) } else { Image(systemName: "play.circle.fill").font(.system(size: 16)) }
                    }.buttonStyle(.borderless).help("Run (⇧↩)")
                    Text(cell.running ? "[*]" : cell.count.map { "[\($0)]" } ?? "[ ]").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 40)
            VStack(alignment: .leading, spacing: 6) {
                if cell.type == "markdown" && !cell.editing {
                    MarkdownCell(text: cell.source.isEmpty ? "*Empty Markdown cell — double-click to edit*" : cell.source)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { cell.editing = true }
                } else {
                    TextEditor(text: $cell.source)
                        .font(.system(size: 13, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: max(36, CGFloat(cell.source.components(separatedBy: "\n").count) * 17 + 12))
                        .padding(6)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.08)))
                        .onChange(of: cell.source) { _, _ in model.changed() }
                        .onKeyPress(.return, phases: .down) { k in
                            if k.modifiers.contains(.shift) { model.run(cell.id, thenNext: true); return .handled }
                            return .ignored
                        }
                }
                ForEach(cell.outputs) { o in output(o) }
            }
            if hover {
                VStack(spacing: 4) {
                    Button { model.move(cell.id, by: -1) } label: { Image(systemName: "arrow.up") }
                    Button { model.move(cell.id, by: 1) } label: { Image(systemName: "arrow.down") }
                    Button { model.add(after: cell.id, type: "code") } label: { Image(systemName: "plus") }.help("Add a code cell below")
                    Button { cell.type = cell.type == "code" ? "markdown" : "code"; cell.editing = true; model.changed() } label: { Image(systemName: cell.type == "code" ? "text.alignleft" : "chevron.left.forwardslash.chevron.right") }.help("Switch cell type")
                    Button { model.delete(cell.id) } label: { Image(systemName: "trash") }
                }.buttonStyle(.borderless).font(.system(size: 11))
            }
        }
        .onHover { hover = $0 }
    }

    @ViewBuilder private func output(_ o: NBOutput) -> some View {
        if let img = o.image {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: min(img.size.width, 760), alignment: .leading)
        } else if !o.text.isEmpty {
            Text(o.text.prefix(100_000)).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(o.isError ? Color.red : Color.primary.opacity(0.85)).textSelection(.enabled)
                .padding(.horizontal, 6).frame(maxWidth: .infinity, alignment: .leading)
                .background(o.isError ? Color.red.opacity(0.06) : Color.clear)
        }
    }
}

/// Rendered Markdown for a notebook cell.
private struct MarkdownCell: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(MDBlock.parse(text)) { b in
                switch b.kind {
                case .heading(let n): Text(md(b.text)).font(.system(size: [22, 18, 16, 14, 13, 13][min(n, 6) - 1], weight: .bold))
                case .code: Text(b.text).font(.system(size: 12, design: .monospaced)).padding(6).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.05))
                case .bullet(let d, let m): Text((m.first?.isNumber == true ? m : "•") + " ") + Text(md(b.text)); let _ = d
                case .quote: Text(md(b.text)).foregroundStyle(.secondary).padding(.leading, 10)
                case .rule: Divider()
                case .paragraph: Text(md(b.text))
                }
            }
        }.textSelection(.enabled).font(.system(size: 13.5))
    }
    func md(_ s: String) -> AttributedString { (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s) }
}

extension Notification.Name { static let zideWillSave = Notification.Name("zide.willSave") }
