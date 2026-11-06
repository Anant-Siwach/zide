import AppKit
import SwiftUI

// MARK: - Refactor preview: a rename (or any multi-file edit from a language server) is listed change by change, grouped
// by file, before anything is written. Untick files to leave them alone.

struct RefactorChange: Identifiable {
    let id = UUID()
    let url: URL
    let line: Int
    let before: String
    let after: String
    let edit: JSON
}

@MainActor
final class RefactorPreviewModel: ObservableObject {
    let title: String
    let changes: [RefactorChange]
    @Published var excluded: Set<URL> = []
    let edit: JSON
    unowned let workspace: Workspace

    init(workspace: Workspace, edit: JSON, title: String) {
        self.workspace = workspace; self.edit = edit; self.title = title
        var out: [RefactorChange] = []
        for (url, edits) in Self.perFile(edit) {
            let text = workspace.documents.first { $0.url == url.standardizedFileURL }?.text ?? (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let lines = text.components(separatedBy: "\n")
            for e in edits {
                guard let r = e["range"] as? JSON, let s = r["start"] as? JSON, let en = r["end"] as? JSON,
                      let sl = s["line"] as? Int, let sc = s["character"] as? Int, let el = en["line"] as? Int, let ec = en["character"] as? Int,
                      lines.indices.contains(sl) else { continue }
                let new = e["newText"] as? String ?? ""
                let line = lines[sl]
                let u = Array(line.utf16)
                let a = min(sc, u.count), b = sl == el ? min(ec, u.count) : u.count
                let after = String(decoding: u[..<a], as: UTF16.self) + new + String(decoding: u[b...], as: UTF16.self)
                out.append(RefactorChange(url: url.standardizedFileURL, line: sl, before: line.trimmingCharacters(in: .whitespaces), after: after.trimmingCharacters(in: .whitespaces), edit: e))
            }
        }
        changes = out.sorted { ($0.url.path, $0.line) < ($1.url.path, $1.line) }
    }

    static func perFile(_ edit: JSON) -> [(URL, [JSON])] {
        var out: [(URL, [JSON])] = []
        if let c = edit["changes"] as? [String: [JSON]] { for (uri, e) in c { if let u = URL(string: uri) { out.append((u, e)) } } }
        for dc in (edit["documentChanges"] as? [JSON]) ?? [] {
            if let td = dc["textDocument"] as? JSON, let uri = td["uri"] as? String, let u = URL(string: uri) { out.append((u, dc["edits"] as? [JSON] ?? [])) }
        }
        return out
    }
    var files: [URL] { Array(Set(changes.map(\.url))).sorted { $0.path < $1.path } }

    func apply() {
        var keep: [String: [JSON]] = [:]
        for c in changes where !excluded.contains(c.url) { keep[c.url.absoluteString, default: []].append(c.edit) }
        // File renames/creates from documentChanges still apply.
        var e: JSON = ["changes": keep]
        let ops = ((edit["documentChanges"] as? [JSON]) ?? []).filter { $0["kind"] != nil }
        if !ops.isEmpty { e["documentChanges"] = ops }
        workspace.apply(workspaceEdit: e)
    }
}

enum RefactorPreview {
    private static var window: NSWindow?

    /// Shows the preview when the edit spans several places; a single change applies at once.
    @MainActor static func show(ws: Workspace, edit: JSON, title: String) {
        let m = RefactorPreviewModel(workspace: ws, edit: edit, title: title)
        if m.changes.count <= 1 && (edit["documentChanges"] as? [JSON])?.contains(where: { $0["kind"] != nil }) != true { ws.apply(workspaceEdit: edit); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = title; w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: RefactorPreviewView(model: m) { apply in
            if apply { m.apply() }
            w.close()
        })
        w.center(); window = w; w.makeKeyAndOrderFront(nil)
    }
}

struct RefactorPreviewView: View {
    @ObservedObject var model: RefactorPreviewModel
    let finish: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(model.changes.count) change\(model.changes.count == 1 ? "" : "s") in \(model.files.count) file\(model.files.count == 1 ? "" : "s")").font(.headline).padding(12)
            Divider()
            List {
                ForEach(model.files, id: \.self) { f in
                    Section {
                        ForEach(model.changes.filter { $0.url == f }) { c in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(c.line + 1)  − \(c.before)").foregroundStyle(.red.opacity(0.85))
                                Text("\(c.line + 1)  + \(c.after)").foregroundStyle(.green)
                            }
                            .font(.system(size: 11.5, design: .monospaced)).lineLimit(1)
                            .opacity(model.excluded.contains(f) ? 0.35 : 1)
                        }
                    } header: {
                        Toggle(isOn: Binding(get: { !model.excluded.contains(f) }, set: { if $0 { model.excluded.remove(f) } else { model.excluded.insert(f) } })) {
                            Text(model.workspace.relative(f)).font(.system(size: 12, weight: .semibold))
                        }.toggleStyle(.checkbox)
                    }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { finish(false) }.keyboardShortcut(.cancelAction)
                Button("Do Refactor") { finish(true) }.keyboardShortcut(.defaultAction).disabled(model.excluded.count == model.files.count)
            }.padding(12)
        }
        .frame(minWidth: 600, minHeight: 360)
    }
}
