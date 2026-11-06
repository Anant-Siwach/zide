import AppKit
import SwiftUI

// MARK: - Debug panel

struct DebugPanel: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var debug: DebugManager
    @ObservedObject var theme = ThemeObserver.shared
    @State private var expr = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                if debug.isActive {
                    if debug.state == .stopped {
                        BarButton(icon: "play.fill", color: .green, help: "Resume (⌥⌘R)") { debug.resume() }
                    } else {
                        BarButton(icon: "pause.fill", help: "Pause") { debug.pause() }
                    }
                    BarButton(icon: "arrow.turn.down.right", help: "Step Over (F8)") { debug.stepOver() }.disabled(debug.state != .stopped)
                    BarButton(icon: "arrow.down.to.line", help: "Step Into (F7)") { debug.stepInto() }.disabled(debug.state != .stopped)
                    BarButton(icon: "arrow.up.to.line", help: "Step Out (⇧F8)") { debug.stepOut() }.disabled(debug.state != .stopped)
                    BarButton(icon: "stop.fill", color: .red, help: "Stop (⌘F2)") { debug.stop() }
                } else {
                    BarButton(icon: "ladybug.fill", color: .green, help: "Debug (⌃D)") { debug.start() }
                }
                Divider().frame(height: 16).padding(.horizontal, 4)
                Text(statusText).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Menu {
                    Button("Remove All Breakpoints") { debug.removeAllBreakpoints() }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
            }
            .padding(.horizontal, 6).frame(height: 30)
            Divider()
            HSplitView {
                frames.frame(minWidth: 160, idealWidth: 240)
                variables.frame(minWidth: 200)
                console.frame(minWidth: 240)
            }
        }
    }

    private var statusText: String {
        switch debug.state {
        case .idle: return "Click in the gutter to set breakpoints, then Debug (⌃D)."
        case .building: return "Building \(debug.targetName)…"
        case .starting: return "Starting \(debug.targetName)…"
        case .running: return "\(debug.targetName) running"
        case .stopped: return "Paused (\(debug.stopReason))"
        case .finished: return "Session ended"
        }
    }

    private var frames: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Frames")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(debug.frames.enumerated()), id: \.offset) { i, f in
                        HStack(spacing: 6) {
                            Image(systemName: f.url != nil ? "doc.text" : "gearshape").font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(f.name).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                            Spacer()
                            if let u = f.url { Text("\(u.lastPathComponent):\(f.line)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(debug.selectedFrame == i ? theme.palette.accent.swiftUI.opacity(0.3) : .clear)
                        .opacity(f.url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false ? 1 : 0.55)
                        .contentShape(Rectangle())
                        .onTapGesture { debug.selectFrame(i) }
                    }
                }
            }
        }
    }

    private var variables: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Variables")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(debug.scopes) { node in VarRow(debug: debug, node: node, depth: 0) }
                }
            }
        }
    }

    private var console: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Console")
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(debug.console) { line in
                            Text(line.text)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(color(line.kind))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(line.id)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: debug.console.count) { _, _ in if let last = debug.console.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            HStack(spacing: 4) {
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
                TextField(debug.state == .stopped ? "Evaluate expression (e.g. p.x + 1)" : "Evaluate (pause first)", text: $expr)
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .onSubmit { debug.evaluate(expr); expr = "" }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(theme.palette.background.swiftUI)
        }
    }

    private func header(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).frame(height: 22)
    }

    private func color(_ k: ConsoleLine.Kind) -> Color {
        switch k {
        case .stdout: return theme.palette.text.swiftUI
        case .stderr, .error: return theme.palette.error.swiftUI
        case .info: return .secondary
        case .input: return theme.palette.info.swiftUI
        case .result: return theme.palette.color(.string).swiftUI
        }
    }
}

private struct VarRow: View {
    @ObservedObject var debug: DebugManager
    @ObservedObject var node: VarNode
    let depth: Int
    @ObservedObject var theme = ThemeObserver.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: node.expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary).frame(width: 10)
                    .opacity(node.expandable ? 1 : 0)
                Text(node.name).font(.system(size: 12, weight: depth == 0 && node.value.isEmpty ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(depth == 0 && node.value.isEmpty ? theme.palette.text.swiftUI : theme.palette.color(.property).swiftUI)
                if !node.value.isEmpty {
                    Text("=").foregroundStyle(.secondary).font(.system(size: 12))
                    Text(node.value).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.palette.color(.string).swiftUI).lineLimit(1).textSelection(.enabled)
                }
                if !node.type.isEmpty { Text(node.type).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1) }
                Spacer()
            }
            .padding(.leading, CGFloat(depth) * 14 + 6)
            .frame(height: 21)
            .contentShape(Rectangle())
            .onTapGesture { if node.expandable { debug.toggle(node) } }
            if node.expanded, let kids = node.children {
                ForEach(kids) { VarRow(debug: debug, node: $0, depth: depth + 1) }
            }
        }
    }
}

// MARK: - TODO

struct TodoPanel: View {
    @ObservedObject var ws: Workspace

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(ws.todos.reduce(0) { $0 + $1.items.count }) TODO items").font(.caption).foregroundStyle(.secondary)
                Spacer()
                BarButton(icon: "arrow.clockwise", help: "Rescan") { ws.scanTodos() }
            }
            .padding(.horizontal, 10).frame(height: 26)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(ws.todos) { g in
                        HStack(spacing: 6) {
                            Image(systemName: FileIcon.symbol(g.url)).foregroundStyle(FileIcon.color(g.url)).font(.system(size: 11))
                            Text(g.url.lastPathComponent).font(.system(size: 12.5, weight: .medium))
                            Text(ws.relative(g.url.deletingLastPathComponent())).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).frame(height: 24)
                        ForEach(g.items) { item in
                            HStack(spacing: 8) {
                                Text("\(item.line + 1)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                                Text(item.preview).font(.system(size: 12)).foregroundStyle(Color(red: 0.5, green: 0.7, blue: 0.95)).lineLimit(1)
                                Spacer()
                            }
                            .frame(height: 22).contentShape(Rectangle())
                            .onTapGesture { ws.openUsage(item) }
                        }
                    }
                }
            }
        }
        .onAppear { if ws.todos.isEmpty { ws.scanTodos() } }
    }
}

// MARK: - Markdown preview

struct MarkdownPreview: View {
    @ObservedObject var doc: EditorDocument
    @ObservedObject var theme = ThemeObserver.shared
    @State private var blocks: [MDBlock] = []
    @State private var timer: Timer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(blocks) { b in block(b) }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .background(theme.palette.background.swiftUI)
        .onAppear { blocks = MDBlock.parse(doc.text) }
        .onReceive(NotificationCenter.default.publisher(for: NSTextStorage.didProcessEditingNotification, object: doc.storage)) { _ in
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                MainActor.assumeIsolated { blocks = MDBlock.parse(doc.text) }
            }
        }
    }

    @ViewBuilder private func block(_ b: MDBlock) -> some View {
        switch b.kind {
        case .heading(let level):
            inline(b.text).font(.system(size: [26, 21, 18, 16, 14, 13][min(level, 6) - 1], weight: .bold)).padding(.top, level <= 2 ? 8 : 4)
            if level <= 2 { Divider() }
        case .code:
            Text(b.text).font(.system(size: 12, design: .monospaced)).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        case .quote:
            HStack(spacing: 10) { Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 3); inline(b.text).foregroundStyle(.secondary) }
        case .bullet(let indent, let marker):
            HStack(alignment: .firstTextBaseline, spacing: 8) { Text(marker).foregroundStyle(.secondary); inline(b.text) }.padding(.leading, CGFloat(indent) * 16)
        case .rule:
            Divider()
        case .paragraph:
            inline(b.text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inline(_ s: String) -> Text {
        Text((try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s))
    }
}

struct MDBlock: Identifiable {
    enum Kind { case heading(Int), code, quote, bullet(Int, String), rule, paragraph }
    let id = UUID()
    let kind: Kind
    let text: String

    static func parse(_ text: String) -> [MDBlock] {
        var out: [MDBlock] = []
        var para: [String] = []
        var code: [String]? = nil
        func flush() { if !para.isEmpty { out.append(MDBlock(kind: .paragraph, text: para.joined(separator: " "))); para = [] } }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if let c = code { out.append(MDBlock(kind: .code, text: c.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                flush()
                let level = line.prefix { $0 == "#" }.count
                out.append(MDBlock(kind: .heading(level), text: line.dropFirst(level).trimmingCharacters(in: .whitespaces)))
            } else if line == "---" || line == "***" || line == "___" {
                flush(); out.append(MDBlock(kind: .rule, text: ""))
            } else if line.hasPrefix(">") {
                flush(); out.append(MDBlock(kind: .quote, text: line.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flush()
                let indent = (raw.prefix { $0 == " " }.count) / 2
                var t = String(line.dropFirst(2))
                var marker = "•"
                if t.hasPrefix("[ ] ") { marker = "☐"; t.removeFirst(4) } else if t.lowercased().hasPrefix("[x] ") { marker = "☑"; t.removeFirst(4) }
                out.append(MDBlock(kind: .bullet(indent, marker), text: t))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty, line[line.index(after: dot)...].hasPrefix(" ") {
                flush()
                out.append(MDBlock(kind: .bullet((raw.prefix { $0 == " " }.count) / 2, String(line[...dot])), text: line[line.index(dot, offsetBy: 2)...].trimmingCharacters(in: .whitespaces)))
            } else {
                para.append(line)
            }
        }
        if let c = code { out.append(MDBlock(kind: .code, text: c.joined(separator: "\n"))) }
        flush()
        return out
    }
}

// MARK: - Local History

@MainActor
enum LocalHistoryWindow {
    private static var window: NSWindow?

    static func show(_ doc: EditorDocument) {
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            return w
        }()
        w.title = "Local History — \(doc.name)"
        w.contentView = NSHostingView(rootView: LocalHistoryView(doc: doc))
        w.makeKeyAndOrderFront(nil)
    }
}

private struct LocalHistoryView: View {
    let doc: EditorDocument
    @State private var versions: [LocalHistory.Version] = []
    @State private var selected: LocalHistory.Version?
    @State private var diff = ""
    @ObservedObject var theme = ThemeObserver.shared

    var body: some View {
        HSplitView {
            List(versions, selection: Binding(get: { selected?.id }, set: { id in selected = versions.first { $0.id == id }; loadDiff() })) { v in
                VStack(alignment: .leading) {
                    Text(v.date.formatted(date: .abbreviated, time: .standard)).font(.system(size: 12.5))
                    Text(RelativeDateTimeFormatter().localizedString(for: v.date, relativeTo: Date())).font(.caption).foregroundStyle(.secondary)
                }.tag(v.id)
            }
            .frame(minWidth: 200, maxWidth: 280)
            VStack(spacing: 0) {
                HStack {
                    Text(selected == nil ? "Select a version" : "Changes from this version to the current file").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Revert to This Version") { revert() }.disabled(selected == nil)
                }
                .padding(8)
                Divider()
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, l in
                            Text(l.isEmpty ? " " : String(l)).font(.system(size: 12, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
                                .background(l.hasPrefix("+") && !l.hasPrefix("+++") ? theme.palette.added.swiftUI.opacity(0.18) : l.hasPrefix("-") && !l.hasPrefix("---") ? theme.palette.error.swiftUI.opacity(0.16) : .clear)
                        }
                    }
                    .textSelection(.enabled)
                }
            }
        }
        .onAppear {
            versions = LocalHistory.versions(doc.url)
            selected = versions.first
            loadDiff()
        }
    }

    private func loadDiff() {
        guard let v = selected else { diff = ""; return }
        let current = FileManager.default.temporaryDirectory.appendingPathComponent("zide-history-current.txt")
        try? doc.text.write(to: current, atomically: true, encoding: .utf8)
        let r = Shell.run("diff", ["-u", v.file.path, current.path])
        diff = r.out.isEmpty ? "(identical to the current file)" : r.out
    }

    private func revert() {
        guard let v = selected, let text = try? String(contentsOf: v.file, encoding: .utf8) else { return }
        let len = doc.storage.length
        doc.editor.replace([(NSRange(location: 0, length: len), text)])
        doc.workspace?.flash("Reverted \(doc.name) — undo with ⌘Z")
    }
}
