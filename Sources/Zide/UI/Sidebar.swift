import AppKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var theme = ThemeObserver.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(ws.sidebarTab.rawValue).font(.system(size: 12.5, weight: .semibold))
                Spacer()
                if ws.sidebarTab == .project {
                    BarButton(icon: "doc.badge.plus", help: "New File") { ws.newFile(in: targetDir) }
                    BarButton(icon: "folder.badge.plus", help: "New Folder") { ws.newFile(in: targetDir, folder: true) }
                    BarButton(icon: "scope", help: "Select Opened File") { if let u = ws.active?.url { ws.reveal(u) } }
                    BarButton(icon: "arrow.down.right.and.arrow.up.left", help: "Collapse All") { ws.expanded = [ws.root]; ws.rebuildRows() }
                } else if ws.sidebarTab == .commit {
                    BarButton(icon: "arrow.clockwise", help: "Refresh") { ws.git.refresh() }
                } else {
                    BarButton(icon: "arrow.clockwise", help: "Refresh") { ws.scheduleSymbols() }
                }
            }
            .padding(.leading, 12).padding(.trailing, 6)
            .frame(height: 34)
            switch ws.sidebarTab {
            case .project: ProjectTree(ws: ws, git: ws.git)
            case .commit: CommitPanel(ws: ws, git: ws.git)
            case .structure: StructurePanel(ws: ws)
            }
        }
        .background(theme.palette.panel.swiftUI)
    }

    private var targetDir: URL {
        guard let sel = ws.selectedFile else { return ws.root }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: sel.path, isDirectory: &isDir)
        return isDir.boolValue ? sel : sel.deletingLastPathComponent()
    }
}

// MARK: - Project tree

private struct ProjectTree: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var git: GitModel

    var body: some View {
        let status = git.statusByPath
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(ws.rows) { row in
                        TreeRowView(ws: ws, row: row, status: status[row.node.url.path] ?? dirStatus(row, status), selected: ws.selectedFile == row.node.url)
                            .id(row.node.url)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: ws.selectedFile) { _, u in if let u { proxy.scrollTo(u) } }
        }
        .contextMenu { treeMenu(for: ws.root) }
    }

    private func dirStatus(_ row: TreeRow, _ status: [String: Character]) -> Character? {
        guard row.node.isDirectory else { return nil }
        let prefix = row.node.url.path + "/"
        return status.keys.contains { $0.hasPrefix(prefix) } ? "M" : nil
    }

    @ViewBuilder private func treeMenu(for url: URL) -> some View {
        Button("New File…") { ws.newFile(in: url) }
        Button("New Folder…") { ws.newFile(in: url, folder: true) }
        Button("Open in Terminal") { ws.terminals.newTerminal(command: "cd \(Shell.quote(url.path))") }
        Button("Find in Folder…") { ws.search.fileMask = ws.relative(url) == url.path ? "" : ws.relative(url) + "/**"; ws.bottomTab = .find; ws.bottomVisible = true }
    }
}

private struct TreeRowView: View {
    @ObservedObject var ws: Workspace
    let row: TreeRow
    let status: Character?
    let selected: Bool
    @ObservedObject var theme = ThemeObserver.shared
    @State private var hover = false

    var body: some View {
        let node = row.node
        HStack(spacing: 4) {
            if node.isDirectory {
                Image(systemName: ws.expanded.contains(node.url) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(width: 12)
                Image(systemName: "folder.fill").font(.system(size: 12)).foregroundStyle(Color(red: 0.55, green: 0.65, blue: 0.85))
            } else {
                Color.clear.frame(width: 12)
                Image(systemName: FileIcon.symbol(node.url)).font(.system(size: 11)).foregroundStyle(FileIcon.color(node.url)).frame(width: 14)
            }
            Text(node.name)
                .font(.system(size: 12.5))
                .foregroundStyle(color)
                .lineLimit(1)
            if hasErrors {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 9)).foregroundStyle(theme.palette.error.swiftUI)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(row.depth) * 14 + 8)
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? theme.palette.accent.swiftUI.opacity(0.3) : (hover ? Color.primary.opacity(0.06) : .clear), in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { if !node.isDirectory { ws.open(node.url) } }
        .simultaneousGesture(TapGesture().onEnded {
            ws.selectedFile = node.url
            if node.isDirectory { ws.toggle(node) } else { ws.open(node.url, focus: false) }
        })
        .contextMenu {
            if !node.isDirectory { Button("Open") { ws.open(node.url) } }
            let dir = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
            Button("New File…") { ws.newFile(in: dir) }
            Button("New Folder…") { ws.newFile(in: dir, folder: true) }
            Divider()
            Button("Rename…") { ws.rename(node.url) }
            Button("Copy Path") { copy(node.url.path) }
            Button("Copy Relative Path") { copy(ws.relative(node.url)) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            Button("Open in Terminal") { ws.terminals.newTerminal(command: "cd \(Shell.quote(dir.path))") }
            if !node.isDirectory, Language.detect(node.url).runFile != nil {
                Button("Run '\(node.name)'") { ws.open(node.url); ws.runner.run(.currentFile) }
            }
            Divider()
            Button("Move to Trash…") { ws.trash(node.url) }
        }
    }

    private var hasErrors: Bool {
        guard !row.node.isDirectory else { return false }
        return ws.problems[row.node.url.standardizedFileURL]?.contains { $0.severity == .error } == true
    }

    private var color: Color {
        let p = theme.palette
        if let status {
            switch status {
            case "?": return p.untracked.swiftUI
            case "A": return p.added.swiftUI
            case "D": return .secondary
            default: return p.modified.swiftUI
            }
        }
        if FileNode.dimmedNames.contains(row.node.name) { return .secondary.opacity(0.7) }
        return p.text.swiftUI
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

// MARK: - Commit

private struct CommitPanel: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var git: GitModel
    @ObservedObject var theme = ThemeObserver.shared

    var body: some View {
        if !git.isRepo {
            VStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 28)).foregroundStyle(.secondary)
                Text("This project isn't a Git repository.").foregroundStyle(.secondary)
                Button("Create Git Repository") { git.initRepo() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Toggle("", isOn: Binding(get: { !git.changes.isEmpty && git.selected.count == git.changes.count },
                                             set: { git.selected = $0 ? Set(git.changes.map(\.path)) : [] }))
                        .toggleStyle(.checkbox).labelsHidden()
                    Text("Changes").font(.system(size: 12, weight: .semibold))
                    Text("\(git.changes.count) files").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(git.changes) { c in
                            ChangeRow(ws: ws, git: git, change: c)
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Amend", isOn: $git.amend).toggleStyle(.checkbox).font(.caption)
                    TextEditor(text: $git.message)
                        .font(.system(size: 12.5))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(theme.palette.background.swiftUI, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(alignment: .topLeading) {
                            if git.message.isEmpty { Text("Commit message").foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false) }
                        }
                        .frame(height: 80)
                    HStack {
                        Button("Commit") { git.commit(andPush: false) }.keyboardShortcut(.return, modifiers: .command)
                        Button("Commit and Push…") { git.commit(andPush: true) }
                        Spacer()
                        Button { ws.assistant.commitMessage() } label: { Image(systemName: "sparkles") }
                            .help("Write the commit message with AI").disabled(git.changes.isEmpty)
                    }
                    .disabled(git.busy != nil)
                }
                .padding(10)
            }
        }
    }
}

private struct ChangeRow: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var git: GitModel
    let change: GitChange
    @ObservedObject var theme = ThemeObserver.shared

    var body: some View {
        let url = ws.root.appendingPathComponent(change.path)
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(get: { git.selected.contains(change.path) }, set: { if $0 { git.selected.insert(change.path) } else { git.selected.remove(change.path) } }))
                .toggleStyle(.checkbox).labelsHidden()
            Image(systemName: FileIcon.symbol(url)).font(.system(size: 11)).foregroundStyle(FileIcon.color(url))
            Text(url.lastPathComponent).font(.system(size: 12.5)).foregroundStyle(color).lineLimit(1)
            Text((change.path as NSString).deletingLastPathComponent).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            Spacer()
            Text(change.label).font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { ws.open(url) }
        .onTapGesture { git.showDiff(change); DiffWindow.show(git: git) }
        .contextMenu {
            Button("Show Diff") { git.showDiff(change); DiffWindow.show(git: git) }
            Button("Open File") { ws.open(url) }
            Divider()
            Button("Rollback…") { git.rollback(change) }
        }
    }

    private var color: Color {
        if change.isUntracked { return theme.palette.untracked.swiftUI }
        if change.index == "A" { return theme.palette.added.swiftUI }
        if change.work == "D" || change.index == "D" { return .secondary }
        return theme.palette.modified.swiftUI
    }
}

/// A window with the selected change's diff, syntax-coloured as a patch.
@MainActor
enum DiffWindow {
    private static var window: NSWindow?

    static func show(git: GitModel) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: DiffView(git: git))
            w.center()
            window = w
        } else {
            window?.contentView = NSHostingView(rootView: DiffView(git: git))
        }
        window?.title = git.diffPath ?? "Diff"
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct DiffView: View {
    @ObservedObject var git: GitModel
    @ObservedObject var theme = ThemeObserver.shared

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(git.diffText.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : String(line))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(color(line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .background(bg(line))
                }
            }
            .textSelection(.enabled)
            .padding(.vertical, 8)
        }
        .background(theme.palette.background.swiftUI)
    }

    private func color(_ l: Substring) -> Color {
        if l.hasPrefix("@@") { return theme.palette.info.swiftUI }
        if l.hasPrefix("diff") || l.hasPrefix("index") || l.hasPrefix("+++") || l.hasPrefix("---") { return .secondary }
        return theme.palette.text.swiftUI
    }

    private func bg(_ l: Substring) -> Color {
        if l.hasPrefix("+") && !l.hasPrefix("+++") { return theme.palette.added.swiftUI.opacity(0.18) }
        if l.hasPrefix("-") && !l.hasPrefix("---") { return theme.palette.error.swiftUI.opacity(0.16) }
        return .clear
    }
}

// MARK: - Structure

private struct StructurePanel: View {
    @ObservedObject var ws: Workspace

    var body: some View {
        if let doc = ws.active {
            if ws.symbols.isEmpty {
                VStack(spacing: 8) {
                    Text(ws.lsp.client(of: doc) == nil ? ws.lspHint(for: doc.language, feature: "Structure") : "No symbols")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { ws.scheduleSymbols() }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(ws.symbols) { s in
                            HStack(spacing: 6) {
                                Image(systemName: SymbolKind.icon(s.kind)).font(.system(size: 11)).foregroundStyle(.purple)
                                Text(s.name).font(.system(size: 12.5)).lineLimit(1)
                                Text(s.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                            }
                            .padding(.leading, CGFloat(s.depth) * 14 + 10)
                            .frame(height: 22)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                ws.pushNavigation()
                                doc.editor.select(s.range)
                                doc.editor.textView.window?.makeFirstResponder(doc.editor.textView)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        } else {
            Text("No file open").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
