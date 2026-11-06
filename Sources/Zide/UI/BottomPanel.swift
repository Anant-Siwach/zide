import AppKit
import SwiftUI

struct BottomPanel: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var theme = ThemeObserver.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(BottomTab.allCases, id: \.self) { tab in
                    Button {
                        ws.bottomTab = tab
                        if tab == .terminal { ws.terminals.ensureOne() }
                        if tab == .git { ws.git.loadLog() }
                    } label: {
                        Text(tab.rawValue).font(.system(size: 12, weight: ws.bottomTab == tab ? .semibold : .regular))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(ws.bottomTab == tab ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                BarButton(icon: "minus", help: "Hide") { ws.bottomVisible = false }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            Divider()
            Group {
                switch ws.bottomTab {
                case .terminal: TerminalTabs(ws: ws, manager: ws.terminals)
                case .run: RunTabs(ws: ws, runner: ws.runner)
                case .debug: DebugPanel(ws: ws, debug: ws.debug)
                case .todo: TodoPanel(ws: ws)
                case .problems: ProblemsView(ws: ws)
                case .find: FindView(ws: ws, search: ws.search)
                case .git: GitLogView(git: ws.git)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.palette.panel.swiftUI)
    }
}

// MARK: - Terminal / Run

private struct SessionTabs<Trailing: View>: View {
    let sessions: [TerminalSession]
    let selected: UUID?
    let select: (TerminalSession) -> Void
    let close: (TerminalSession) -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(sessions) { s in SessionChip(session: s, selected: s.id == selected, select: { select(s) }, close: { close(s) }) }
                }
            }
            trailing
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
    }
}

private struct SessionChip: View {
    @ObservedObject var session: TerminalSession
    let selected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            if session.isRun {
                Circle().fill(session.running ? Color.green : (session.exitCode == 0 ? Color.secondary : Color.red)).frame(width: 7, height: 7)
            } else {
                Image(systemName: "terminal").font(.system(size: 10))
            }
            Text(session.title).font(.system(size: 11.5)).lineLimit(1)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(selected ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }
}

private struct TerminalTabs: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var manager: TerminalManager

    var body: some View {
        VStack(spacing: 0) {
            SessionTabs(sessions: manager.sessions, selected: manager.current?.id, select: { manager.selected = $0.id }, close: { manager.close($0) }) {
                BarButton(icon: "plus", help: "New Terminal (⌘T in terminal)") { manager.newTerminal() }
            }
            if let s = manager.current {
                TerminalHost(session: s).id(s.id)
            } else {
                Button("New Terminal") { manager.newTerminal() }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { manager.ensureOne() }
    }
}

private struct RunTabs: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var runner: RunManager

    var body: some View {
        VStack(spacing: 0) {
            SessionTabs(sessions: runner.runs, selected: runner.currentRun?.id, select: { runner.selectedRun = $0.id }, close: { runner.close($0) }) {
                if let cur = runner.currentRun {
                    BarButton(icon: "arrow.clockwise", color: .green, help: "Rerun") {
                        if let cfg = runner.configs.first(where: { $0.name == cur.title }) { runner.run(cfg) } else { runner.run() }
                    }
                    BarButton(icon: "stop.fill", color: cur.running ? .red : .secondary, help: "Stop") { cur.terminate() }
                }
            }
            if let s = runner.currentRun {
                TerminalHost(session: s).id(s.id)
            } else {
                VStack(spacing: 8) {
                    Text("Nothing running").foregroundStyle(.secondary)
                    Button("Run '\(runner.selectedName)'") { runner.run() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let v = session.view
        v.removeFromSuperview()
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            v.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        session.applyTheme()
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Problems

private struct ProblemsView: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var theme = ThemeObserver.shared

    var body: some View {
        let files = ws.problems.keys.sorted { a, b in
            let ea = ws.problems[a]!.contains { $0.severity == .error }, eb = ws.problems[b]!.contains { $0.severity == .error }
            return ea != eb ? ea : ws.relative(a) < ws.relative(b)
        }
        if files.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle").font(.system(size: 22)).foregroundStyle(.green)
                Text("No problems found").foregroundStyle(.secondary)
                Text("Problems come from language servers for the files you open.").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(files, id: \.self) { url in
                        let items = ws.problems[url]!.sorted { ($0.severity.rawValue, $0.line) < ($1.severity.rawValue, $1.line) }
                        HStack(spacing: 6) {
                            Image(systemName: FileIcon.symbol(url)).foregroundStyle(FileIcon.color(url)).font(.system(size: 11))
                            Text(url.lastPathComponent).font(.system(size: 12.5, weight: .medium))
                            Text(ws.relative(url.deletingLastPathComponent())).font(.caption).foregroundStyle(.secondary)
                            Text("\(items.count)").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).frame(height: 24)
                        ForEach(items) { d in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: d.severity == .error ? "xmark.octagon.fill" : d.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                    .foregroundStyle(d.severity == .error ? theme.palette.error.swiftUI : d.severity == .warning ? theme.palette.warning.swiftUI : theme.palette.info.swiftUI)
                                    .font(.system(size: 10.5))
                                Text(d.message).font(.system(size: 12)).lineLimit(2)
                                Text(":\(d.line + 1)").font(.system(size: 11)).foregroundStyle(.secondary)
                                Spacer()
                                Menu {
                                    Button("Explain with AI") { ws.assistant.explain(d, in: url) }
                                    Button("Fix with AI") { ws.assistant.fix(d, in: url) }
                                } label: { Image(systemName: "sparkles").font(.system(size: 11)) }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Explain or fix with the AI assistant")
                            }
                            .padding(.leading, 30).padding(.vertical, 3)
                            .contentShape(Rectangle())
                            .onTapGesture { ws.openUsage(UsageItem(url: url, line: d.line, column: d.column, length: d.range.length, preview: "")) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Find / usages

private struct FindView: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var search: SearchModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in files", text: $search.query).textFieldStyle(.roundedBorder).focused($focused).onSubmit { search.run() }
                Toggle("Cc", isOn: $search.caseSensitive).toggleStyle(.button).help("Match case")
                Toggle("W", isOn: $search.wholeWord).toggleStyle(.button).help("Words")
                Toggle(".*", isOn: $search.regex).toggleStyle(.button).help("Regex")
                TextField("File mask (e.g. *.ts)", text: $search.fileMask).textFieldStyle(.roundedBorder).frame(width: 150).onSubmit { search.run() }
                Toggle(isOn: $search.showReplace) { Image(systemName: "arrow.left.arrow.right") }.toggleStyle(.button).help("Replace")
                if search.running { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)
            .padding(.horizontal, 10).padding(.vertical, 6)
            if search.showReplace {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
                    TextField("Replace with", text: $search.replacement).textFieldStyle(.roundedBorder)
                    Button("Replace All") { search.replaceAll() }.disabled(ws.usages.isEmpty)
                }
                .controlSize(.small)
                .padding(.horizontal, 10).padding(.bottom, 6)
            }
            if !ws.usagesTitle.isEmpty {
                HStack { Text(ws.usagesTitle).font(.caption).foregroundStyle(.secondary); Spacer() }.padding(.horizontal, 12).padding(.bottom, 4)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(ws.usages) { g in
                        HStack(spacing: 6) {
                            Image(systemName: FileIcon.symbol(g.url)).foregroundStyle(FileIcon.color(g.url)).font(.system(size: 11))
                            Text(g.url.lastPathComponent).font(.system(size: 12.5, weight: .medium))
                            Text(ws.relative(g.url.deletingLastPathComponent())).font(.caption).foregroundStyle(.secondary)
                            Text("\(g.items.count)").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).frame(height: 24)
                        ForEach(g.items) { item in
                            HStack(spacing: 8) {
                                Text("\(item.line + 1)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                                Text(item.preview).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                                Spacer()
                            }
                            .frame(height: 22)
                            .contentShape(Rectangle())
                            .onTapGesture { ws.openUsage(item) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear { if ws.usages.isEmpty { focused = true } }
    }
}

// MARK: - Git log

private struct GitLogView: View {
    @ObservedObject var git: GitModel

    var body: some View {
        if !git.isRepo {
            Text("Not a Git repository").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(git.log.enumerated()), id: \.offset) { _, e in
                        HStack(spacing: 10) {
                            Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                            Text(e.subject).font(.system(size: 12.5)).lineLimit(1)
                            Spacer()
                            Text(e.author).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            Text(e.date).font(.system(size: 11.5)).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                            Text(e.hash).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12).frame(height: 24)
                        .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            }
            .onAppear { git.loadLog() }
        }
    }
}
