import AppKit
import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var theme = ThemeObserver.shared
    @ObservedObject var palette: PaletteModel
    // HSplitView ignores ideal widths and splits the window in half; a fixed, draggable width doesn't.
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 250
    @AppStorage("assistantWidth") private var assistantWidth: Double = 360

    init(ws: Workspace) {
        self.ws = ws
        self.palette = ws.palette
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(ws: ws, git: ws.git, runner: ws.runner)
            Rectangle().fill(theme.palette.chromeBorder.swiftUI).frame(height: 1)
            HStack(spacing: 0) {
                if !ws.zen {
                    ToolStripe(ws: ws)
                    Rectangle().fill(theme.palette.chromeBorder.swiftUI).frame(width: 1)
                }
                VSplitView {
                    HStack(spacing: 0) {
                        if ws.sidebarVisible && !ws.zen {
                            SidebarView(ws: ws).frame(width: sidebarWidth)
                            SplitHandle(width: $sidebarWidth)
                        }
                        EditorArea(ws: ws)
                            .frame(maxWidth: ws.zen ? 860 : .infinity)
                            .frame(minWidth: 300, maxWidth: .infinity)
                            .background(theme.palette.background.swiftUI)
                        if ws.assistantVisible && !ws.zen {
                            SplitHandle(width: $assistantWidth, reversed: true)
                            AssistantPanel(ws: ws, model: ws.assistant).frame(width: assistantWidth)
                        }
                    }
                    .frame(minHeight: 200)
                    if ws.bottomVisible && !ws.zen {
                        BottomPanel(ws: ws)
                            .frame(minHeight: 110, idealHeight: 240)
                    }
                }
            }
            if !ws.zen {
                Rectangle().fill(theme.palette.chromeBorder.swiftUI).frame(height: 1)
                StatusBar(ws: ws, lsp: ws.lsp, git: ws.git)
            }
        }
        .background(theme.palette.chrome.swiftUI)
        .overlay(alignment: .top) {
            if palette.visible { PaletteView(model: palette).padding(.top, 70) }
        }
        .overlay(alignment: .bottom) {
            if let m = ws.flashMessage {
                Text(m)
                    .font(.system(size: 12))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                    .padding(.bottom, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { ws.flashMessage = nil }
            }
        }
        .animation(.easeOut(duration: 0.18), value: ws.flashMessage)
        .foregroundStyle(theme.palette.text.swiftUI)
    }
}

// MARK: - Top bar

private struct TopBar: View {
    /// A note opened on its own has nothing to run; projects and runnable files keep the run controls.
    private var showRun: Bool {
        !ws.isQuick || runner.isRunning || ws.debug.isActive || (ws.active.map { $0.language.runFile != nil && !$0.language.isProse } ?? false)
    }

    @ObservedObject var ws: Workspace
    @ObservedObject var git: GitModel
    @ObservedObject var runner: RunManager
    @ObservedObject var theme = ThemeObserver.shared
    @ObservedObject var debug: DebugManager

    init(ws: Workspace, git: GitModel, runner: RunManager) {
        self.ws = ws; self.git = git; self.runner = runner; self.debug = ws.debug
    }

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 72, height: 1) // traffic lights
            Menu {
                ForEach(Prefs.shared.recentProjects.filter { $0 != ws.root }.prefix(12), id: \.self) { url in
                    Button(url.lastPathComponent) { AppDelegate.shared.openProject(url) }
                }
                Divider()
                Button("Open…") { AppDelegate.shared.openPanel() }
                Button("Close Project") { ws.window?.performClose(nil) }
            } label: {
                // A menu button only renders the first view of a custom label, so keep it to one Label.
                Label(ws.isQuick ? (ws.active?.name ?? ws.name) : ws.name, systemImage: ws.isQuick ? "doc.text" : "folder.fill")
                    .font(.system(size: 13, weight: .semibold))
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help(ws.isQuick ? (ws.quickFile?.path ?? "") : ws.root.path)
            if git.isRepo {
                Menu {
                    ForEach(git.branches, id: \.self) { b in
                        Button { git.checkout(b) } label: { if b == git.branch { Label(b, systemImage: "checkmark") } else { Text(b) } }
                    }
                    Divider()
                    Button("New Branch…") { git.newBranch() }
                    Button("Pull") { git.pull() }
                    Button("Push") { git.push() }
                    Button("Fetch") { git.fetch() }
                } label: {
                    Label(git.branch + (git.ahead > 0 ? " ↑\(git.ahead)" : "") + (git.behind > 0 ? " ↓\(git.behind)" : ""), systemImage: "arrow.triangle.branch")
                        .font(.system(size: 12.5))
                }
                .menuStyle(.borderlessButton).fixedSize()
                if !git.changes.isEmpty {
                    Button { ws.sidebarTab = .commit; ws.sidebarVisible = true } label: {
                        HStack(spacing: 3) { Circle().fill(Color.orange).frame(width: 6, height: 6); Text("\(git.changes.count)").monospacedDigit() }
                            .font(.system(size: 11.5, weight: .medium))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain).help("\(git.changes.count) changed file\(git.changes.count == 1 ? "" : "s") — open Commit (⌘0)")
                }
            }
            Spacer(minLength: 12)
            CenterPill(ws: ws, lsp: ws.lsp, git: git, runner: runner)
            Spacer(minLength: 12)
            if showRun {
            Menu {
                ForEach(runner.configs) { c in
                    Button { runner.select(c.name) } label: { if c.name == runner.selectedName { Label(c.name, systemImage: "checkmark") } else { Text(c.name) } }
                }
                Divider()
                Button("Edit Configurations…") { RunConfigEditor.present(ws: ws) }
            } label: {
                Label(runner.selectedName, systemImage: runner.selected.name == RunConfig.currentFile.name ? "doc" : "gearshape.2")
                    .font(.system(size: 12.5))
            }
            .menuStyle(.borderlessButton).fixedSize()
            BarButton(icon: "play.fill", color: .green, help: "Run '\(runner.selectedName)' (⌃R)") { runner.run() }
            BarButton(icon: "ladybug.fill", color: .green, help: "Debug '\(runner.selectedName)' (⌃D)") { ws.debug.start() }
            BarButton(icon: "stop.fill", color: runner.isRunning || ws.debug.isActive ? .red : .secondary, help: "Stop (⌘F2)") { runner.stop(); ws.debug.stop() }
                .disabled(!runner.isRunning && !ws.debug.isActive)
            Divider().frame(height: 18).padding(.horizontal, 4)
            }
            if let d = ws.active, PaneViewTypes.web.contains(d.url.pathExtension.lowercased()) {
                ToggleButton(icon: "globe", on: ws.livePreview, help: "Live web preview (⌥⇧⌘P)") { ws.livePreview.toggle() }
            }
            if let d = ws.active, d.language.id == "markdown" {
                ToggleButton(icon: "doc.richtext", on: ws.markdownPreview, help: "Markdown preview (⇧⌘P)") { ws.markdownPreview.toggle() }
            }
            if let d = ws.active, d.url.pathExtension.lowercased() == "ipynb" {
                ToggleButton(icon: "curlybraces", on: ws.notebookAsText, help: "Show the notebook as JSON") { ws.notebookAsText.toggle() }
            }
            ToggleButton(icon: "sidebar.left", on: ws.sidebarVisible, help: "Project sidebar (⌘1)") { ws.sidebarVisible.toggle() }
            ToggleButton(icon: "rectangle.bottomthird.inset.filled", on: ws.bottomVisible, help: "Bottom panel: terminal, run, problems") {
                ws.bottomVisible.toggle(); if ws.bottomVisible && ws.bottomTab == .terminal { ws.terminals.ensureOne() }
            }
            ToggleButton(icon: "sparkles", on: ws.assistantVisible, help: "AI assistant (⌘I)") { ws.assistantVisible.toggle() }
            Divider().frame(height: 18).padding(.horizontal, 2)
            BarButton(icon: "gearshape", help: "Settings (⌘,)") { SettingsWindow.show() }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(theme.palette.chrome.swiftUI)
    }
}

struct BarButton: View {
    let icon: String
    var color: Color = .secondary
    var help = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 28, height: 26)
                .background(hover ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - Tool window stripe

private struct ToolStripe: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var theme = ThemeObserver.shared

    var body: some View {
        VStack(spacing: 4) {
            stripe("folder", "Project (⌘1)", active: ws.sidebarVisible && ws.sidebarTab == .project) { toggleSidebar(.project) }
            stripe("arrow.triangle.branch", "Commit (⌘0)", active: ws.sidebarVisible && ws.sidebarTab == .commit) { toggleSidebar(.commit) }
            stripe("list.bullet.indent", "Structure (⌘7)", active: ws.sidebarVisible && ws.sidebarTab == .structure) { toggleSidebar(.structure) }
            stripe("sparkles", "AI Assistant (⌘I)", active: ws.assistantVisible) { ws.assistantVisible.toggle() }
            Spacer()
            stripe("play.rectangle", "Run (⌘4)", active: ws.bottomVisible && ws.bottomTab == .run) { toggleBottom(.run) }
            stripe("ladybug", "Debug (⌘5)", active: ws.bottomVisible && ws.bottomTab == .debug) { toggleBottom(.debug) }
            stripe("terminal", "Terminal (⌥F12)", active: ws.bottomVisible && ws.bottomTab == .terminal) { toggleBottom(.terminal) }
            stripe("exclamationmark.circle", "Problems (⌘6)", active: ws.bottomVisible && ws.bottomTab == .problems) { toggleBottom(.problems) }
            stripe("text.magnifyingglass", "Find (⇧⌘F)", active: ws.bottomVisible && ws.bottomTab == .find) { toggleBottom(.find) }
            stripe("checklist", "TODO", active: ws.bottomVisible && ws.bottomTab == .todo) { toggleBottom(.todo); ws.scanTodos() }
            stripe("clock.arrow.circlepath", "Git Log (⌘9)", active: ws.bottomVisible && ws.bottomTab == .git) { toggleBottom(.git) }
        }
        .padding(.vertical, 8)
        .frame(width: 40)
        .background(theme.palette.chrome.swiftUI)
    }

    private func toggleSidebar(_ tab: SidebarTab) {
        if ws.sidebarVisible && ws.sidebarTab == tab { ws.sidebarVisible = false } else { ws.sidebarTab = tab; ws.sidebarVisible = true }
        if tab == .structure { ws.scheduleSymbols() }
    }

    private func toggleBottom(_ tab: BottomTab) {
        if ws.bottomVisible && ws.bottomTab == tab { ws.bottomVisible = false } else {
            ws.bottomTab = tab; ws.bottomVisible = true
            if tab == .terminal { ws.terminals.ensureOne() }
            if tab == .git { ws.git.loadLog() }
        }
    }

    private func stripe(_ icon: String, _ help: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .frame(width: 30, height: 30)
                .foregroundStyle(active ? .white : .secondary)
                .background(active ? theme.palette.accent.swiftUI : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Editor area (tabs + editor)

private struct EditorArea: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var theme = ThemeObserver.shared

    var body: some View {
        if ws.panes.count > 1 {
            HSplitView {
                PaneView(ws: ws, pane: ws.panes[0], index: 0).frame(minWidth: 220)
                PaneView(ws: ws, pane: ws.panes[1], index: 1).frame(minWidth: 220)
            }
        } else {
            PaneView(ws: ws, pane: ws.panes[0], index: 0)
        }
    }
}

/// One split: its tab strip, the editor, and (for Markdown) an optional live preview.
private struct PaneView: View {
    static let webExts: Set<String> = ["html", "htm", "xhtml", "css", "js", "mjs", "jsx", "ts", "tsx", "svg"]
    @ObservedObject var ws: Workspace
    @ObservedObject var pane: EditorPane
    let index: Int
    @ObservedObject var theme = ThemeObserver.shared

    var body: some View {
        VStack(spacing: 0) {
            if !pane.tabs.isEmpty {
                TabStrip(ws: ws, pane: pane, index: index)
                Rectangle().fill(theme.palette.chromeBorder.swiftUI).frame(height: 1)
            }
            if let doc = pane.active, !ws.isQuick {
                Breadcrumbs(ws: ws, url: doc.url)
            }
            if let doc = pane.active {
                if ws.markdownPreview && doc.language.id == "markdown" {
                    HSplitView {
                        EditorHost(document: doc, pane: index).id("\(doc.id)-\(index)").frame(minWidth: 200)
                        MarkdownPreview(doc: doc).frame(minWidth: 200)
                    }
                } else if ws.livePreview && Self.webExts.contains(doc.url.pathExtension.lowercased()) {
                    HSplitView {
                        EditorHost(document: doc, pane: index).id("\(doc.id)-\(index)").frame(minWidth: 200)
                        LivePreviewPane(model: ws.preview, doc: doc).frame(minWidth: 240)
                    }
                } else if doc.url.isDatabase {
                    DatabaseFileView(url: doc.url).id("\(doc.id)-db")
                } else if doc.url.pathExtension.lowercased() == "ipynb" && !ws.notebookAsText {
                    NotebookView(ws: ws, doc: doc).id("\(doc.id)-nb")
                } else if ["http", "rest"].contains(doc.url.pathExtension.lowercased()) {
                    HSplitView {
                        EditorHost(document: doc, pane: index).id("\(doc.id)-\(index)").frame(minWidth: 240)
                        HTTPPane(doc: doc).frame(minWidth: 280)
                    }
                } else if doc.url.mediaKind != nil {
                    MediaViewer(url: doc.url).id("\(doc.id)-media")
                } else {
                    EditorHost(document: doc, pane: index).id("\(doc.id)-\(index)")
                }
            } else {
                EmptyEditor(ws: ws)
            }
        }
        .background(theme.palette.background.swiftUI)
        .overlay(alignment: .top) {
            // Thin accent line marks the focused split.
            if ws.panes.count > 1 && ws.focusedPane == index { Rectangle().fill(theme.palette.accent.swiftUI).frame(height: 2) }
        }
    }
}

private struct EmptyEditor: View {
    var ws: Workspace? = nil
    @ObservedObject var theme = ThemeObserver.shared

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(ws?.name ?? "Zide").font(.system(size: 17, weight: .semibold))
                Text("No file open").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("RECENT").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                    let recent = Array((ws?.recentFileURLs ?? []).prefix(6))
                    if recent.isEmpty { Text("Nothing yet").font(.system(size: 12.5)).foregroundStyle(.secondary) }
                    ForEach(recent, id: \.self) { url in
                        Button { ws?.open(url) } label: {
                            HStack(spacing: 7) {
                                Image(systemName: FileIcon.symbol(url)).foregroundStyle(FileIcon.color(url)).frame(width: 14)
                                Text(url.lastPathComponent).lineLimit(1)
                            }
                            .font(.system(size: 12.5))
                        }
                        .buttonStyle(.plain)
                    }
                    HStack(spacing: 10) {
                        Button("New File") { ws?.newFile(in: ws?.root ?? URL(fileURLWithPath: NSHomeDirectory())) }
                        Button("Open…") { AppDelegate.shared.openPanel() }
                    }
                    .controlSize(.small).padding(.top, 6)
                }
                .frame(width: 200, alignment: .leading)
                VStack(alignment: .leading, spacing: 7) {
                    Text("SHORTCUTS").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach([("Search Everywhere", "⇧⇧"), ("Go to File", "⇧⌘O"), ("Recent Files", "⌘E"), ("Find Action", "⇧⌘A"), ("Find in Files", "⇧⌘F"), ("Terminal", "⌥F12"), ("Split Right", "⌘\\")], id: \.0) { item in
                        HStack(spacing: 12) {
                            Text(item.0).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                            Text(item.1).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Color.accentColor)
                        }
                        .font(.system(size: 12.5))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Draggable divider for the project sidebar.
private struct SplitHandle: View {
    @Binding var width: Double
    /// For a panel on the right: dragging left makes it wider.
    var reversed = false
    @ObservedObject var theme = ThemeObserver.shared
    @State private var start: Double?

    var body: some View {
        Rectangle().fill(theme.palette.chromeBorder.swiftUI).frame(width: 1)
            .overlay(Color.clear.frame(width: 7).contentShape(Rectangle())
                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        if start == nil { start = width }
                        width = min(reversed ? 800 : 560, max(170, start! + (reversed ? -1 : 1) * v.translation.width))
                    }
                    .onEnded { _ in start = nil }))
    }
}

/// Path of the open file inside the project; clicking a folder reveals it in the tree.
private struct Breadcrumbs: View {
    let ws: Workspace
    let url: URL
    @ObservedObject var theme = ThemeObserver.shared

    var body: some View {
        let parts = ws.relative(url).split(separator: "/").map(String.init)
        HStack(spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                if i > 0 { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary) }
                let last = i == parts.count - 1
                Button {
                    let target = parts[0...i].reduce(ws.root) { $0.appendingPathComponent($1) }
                    ws.reveal(last ? url : target.appendingPathComponent("."))
                } label: {
                    HStack(spacing: 4) {
                        if last { Image(systemName: FileIcon.symbol(url)).foregroundStyle(FileIcon.color(url)) }
                        Text(part)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(last ? .primary : .secondary)
            }
            Spacer()
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 12)
        .frame(height: 22)
        .background(theme.palette.background.swiftUI)
    }
}

/// Words and characters of a note (recounted as you type; skipped for very large files).
private struct WordCount: View {
    @ObservedObject var doc: EditorDocument
    var body: some View {
        let text = doc.storage.string
        if text.utf16.count < 2_000_000 {
            var words = 0
            text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in words += 1 }
            return AnyView(Text("\(words) words · \(text.count) chars"))
        }
        return AnyView(EmptyView())
    }
}

private struct TabStrip: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var pane: EditorPane
    let index: Int
    @ObservedObject var theme = ThemeObserver.shared

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(pane.tabs) { doc in
                        TabItem(ws: ws, doc: doc, pane: index, selected: doc === pane.active).id(doc.id)
                    }
                }
            }
            .onChange(of: pane.active?.id) { _, id in if let id { withAnimation { proxy.scrollTo(id) } } }
        }
        .frame(height: 34)
        .background(theme.palette.chrome.swiftUI)
    }
}

private struct TabItem: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var doc: EditorDocument
    let pane: Int
    let selected: Bool
    @ObservedObject var theme = ThemeObserver.shared
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: FileIcon.symbol(doc.url)).font(.system(size: 11)).foregroundStyle(FileIcon.color(doc.url))
            Text(doc.name)
                .font(.system(size: 12.5))
                .foregroundStyle(hasErrors ? theme.palette.error.swiftUI : (selected ? theme.palette.text.swiftUI : .secondary))
                .underline(hasErrors, pattern: .dot, color: theme.palette.error.swiftUI)
            ZStack {
                if doc.isDirty && !hover { Circle().fill(Color.secondary).frame(width: 7, height: 7) }
                if hover || selected {
                    Button { ws.closeDocument(doc, pane: pane) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).opacity(hover ? 1 : 0.6)
                }
            }
            .frame(width: 14)
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(selected ? theme.palette.tabActive.swiftUI : (hover ? Color.primary.opacity(0.05) : .clear))
        .overlay(alignment: .bottom) { if selected { Rectangle().fill(theme.palette.accent.swiftUI).frame(height: 2) } }
        .contentShape(Rectangle())
        .onTapGesture { ws.focusedPane = pane; ws.active = doc; ws.focusActiveEditor() }
        .onHover { hover = $0 }
        .help(ws.relative(doc.url))
        .contextMenu {
            Button("Close") { ws.closeDocument(doc, pane: pane) }
            Button("Close Other Tabs") { ws.focusedPane = pane; ws.closeOthers(doc) }
            Button("Close All Tabs") { ws.closeAll() }
            Divider()
            Button("Split Right") { ws.focusedPane = pane; ws.active = doc; ws.splitRight() }
            Button("Move to Other Split") { ws.focusedPane = pane; ws.active = doc; ws.moveToOtherSplit() }
            if ws.panes.count > 1 { Button("Unsplit") { ws.unsplit() } }
            Divider()
            Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(doc.url.path, forType: .string) }
            Button("Copy Relative Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ws.relative(doc.url), forType: .string) }
            Button("Select in Project View") { ws.reveal(doc.url) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([doc.url]) }
        }
    }

    private var hasErrors: Bool { doc.diagnostics.contains { $0.severity == .error } }
}

/// Hosts the document's AppKit editor (kept alive per document so undo/scroll survive tab switches).
struct EditorHost: NSViewRepresentable {
    let document: EditorDocument
    var pane = 0

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let sv = document.editor(pane: pane).scrollView
        sv.removeFromSuperview()
        sv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sv)
        NSLayoutConstraint.activate([
            sv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            sv.topAnchor.constraint(equalTo: container.topAnchor),
            sv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Status bar

private struct StatusBar: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var lsp: LSPManager
    @ObservedObject var git: GitModel
    @ObservedObject var theme = ThemeObserver.shared

    var body: some View {
        HStack(spacing: 14) {
            let counts = ws.problemCounts
            Button { ws.bottomTab = .problems; ws.bottomVisible = true } label: {
                HStack(spacing: 8) {
                    Label("\(counts.errors)", systemImage: "xmark.octagon.fill").foregroundStyle(counts.errors > 0 ? theme.palette.error.swiftUI : .secondary)
                    Label("\(counts.warnings)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(counts.warnings > 0 ? theme.palette.warning.swiftUI : .secondary)
                }
            }
            .buttonStyle(.plain)
            .help("Problems")
            if let r = ws.remote { RemoteBadge(session: r) }
            if let p = lsp.progress {
                ProgressView().controlSize(.mini)
                Text(p).lineLimit(1).foregroundStyle(.secondary).frame(maxWidth: 280, alignment: .leading)
            }
            Spacer()
            if Prefs.shared.showBlame && !git.blame.isEmpty {
                Label(git.blame, systemImage: "person.crop.circle").lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary).frame(maxWidth: 340, alignment: .trailing)
            }
            if let doc = ws.active { DocStatus(ws: ws, doc: doc, lsp: lsp) }
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(theme.palette.chrome.swiftUI)
    }
}

private struct DocStatus: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var doc: EditorDocument
    @ObservedObject var lsp: LSPManager
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        HStack(spacing: 14) {
            if let kind = doc.url.mediaKind {
                Text(kind == .pdf ? "PDF" : "Image")
            } else {
                serverStatus
                Button { doc.editor.promptGoToLine() } label: {
                    Text("\(doc.cursorLine):\(doc.cursorColumn)" + (doc.selectionLength > 0 ? " (\(doc.selectionLength) chars)" : ""))
                }.buttonStyle(.plain)
                if doc.language.isProse { WordCount(doc: doc) }
                DocFormatMenus(doc: doc)
                Text(doc.language.name)
            }
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var serverStatus: some View {
        switch lsp.status(for: doc.language) {
        case .ready(let cmd):
            Label(cmd, systemImage: "bolt.fill").foregroundStyle(.green.opacity(0.85)).help("Language server running")
        case .starting(let cmd):
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text(cmd) }
        case .missing(let spec):
            Button { ws.installServer(spec, for: doc.language) } label: {
                Label("Install \(spec.command)", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.plain).foregroundStyle(Color.accentColor)
            .help("Smart features for \(doc.language.name) need \(spec.command). Click to run: \(spec.install)")
        case .failed(let cmd, let msg):
            Button { lsp.restart(doc.language) } label: { Label("\(cmd) failed — restart", systemImage: "exclamationmark.triangle") }
                .buttonStyle(.plain).foregroundStyle(.orange).help(msg)
        case .none:
            EmptyView()
        }
    }
}

// MARK: - Palette

struct PaletteView: View {
    @ObservedObject var model: PaletteModel
    @ObservedObject var theme = ThemeObserver.shared
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.mode == .custom {
                HStack { Text(model.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary); Spacer() }
                    .padding(.horizontal, 14).padding(.top, 10)
            } else {
                HStack(spacing: 2) {
                    ForEach([PaletteModel.Mode.all, .files, .symbols, .actions, .text, .tasks], id: \.self) { m in
                        Button { model.mode = m; model.query = model.query } label: {
                            Text(m.rawValue).font(.system(size: 12, weight: model.mode == m ? .semibold : .regular))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(model.mode == m ? theme.palette.accent.swiftUI.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                    Text("Tab to switch").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10).padding(.top, 8)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(placeholder, text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { model.accept() }
                    .onKeyPress(.downArrow) { model.move(1); return .handled }
                    .onKeyPress(.upArrow) { model.move(-1); return .handled }
                    .onKeyPress(.escape) { model.close(); return .handled }
                    .onKeyPress(.tab) { model.cycleMode(); return .handled }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { i, item in
                            PaletteRow(item: item, selected: i == model.selected)
                                .id(i)
                                .onTapGesture { model.selected = i; model.accept() }
                        }
                        if model.results.isEmpty {
                            Text(model.query.isEmpty ? "Type to search" : "Nothing found").foregroundStyle(.secondary).padding(20)
                        }
                    }
                    .padding(6)
                }
                .frame(height: 360)
                .onChange(of: model.selected) { _, s in proxy.scrollTo(s) }
            }
        }
        .frame(width: 640)
        .background(theme.palette.panel.swiftUI, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
        .onAppear { focused = true }
        .onExitCommand { model.close() }
    }

    private var placeholder: String {
        switch model.mode {
        case .files: return "Go to file (name or path, add :line)"
        case .symbols: return "Go to symbol"
        case .actions: return "Find action"
        case .text: return "Search text in all files"
        case .tasks: return "Run a task (scripts, make targets, run configurations)"
        case .custom: return "Filter"
        case .all: return "Search files, symbols, actions and tasks"
        }
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool
    @ObservedObject var theme = ThemeObserver.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon).foregroundStyle(item.iconColor).frame(width: 18)
            Text(item.title).font(.system(size: 13)).lineLimit(1)
            Text(item.subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            Spacer()
            if !item.shortcut.isEmpty { Text(item.shortcut).font(.system(size: 11.5)).foregroundStyle(.secondary) }
        }
        .padding(.leading, 8 + CGFloat(item.indent) * 14).padding(.trailing, 8)
        .frame(height: 28)
        .background(selected ? theme.palette.accent.swiftUI.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

// MARK: - Run configurations editor

enum RunConfigEditor {
    @MainActor
    static func present(ws: Workspace) {
        let a = NSAlert()
        a.messageText = "Add Run Configuration"
        a.informativeText = "Runs in the project folder through your login shell."
        let name = NSTextField(string: "")
        name.placeholderString = "Name (e.g. Dev server)"
        let cmd = NSTextField(string: "")
        cmd.placeholderString = "Command (e.g. npm run dev)"
        let stack = NSStackView(views: [name, cmd])
        stack.orientation = .vertical
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: 56)
        name.frame.size.width = 340
        cmd.frame.size.width = 340
        a.accessoryView = stack
        a.addButton(withTitle: "Add")
        a.addButton(withTitle: "Cancel")
        if ws.runner.selected.custom { a.addButton(withTitle: "Delete '\(ws.runner.selected.name)'") }
        a.window.initialFirstResponder = name
        switch a.runModal() {
        case .alertFirstButtonReturn:
            let n = name.stringValue.trimmingCharacters(in: .whitespaces), c = cmd.stringValue.trimmingCharacters(in: .whitespaces)
            if !n.isEmpty && !c.isEmpty { ws.runner.addCustom(name: n, command: c) }
        case .alertThirdButtonReturn:
            ws.runner.removeCustom(ws.runner.selected.name)
        default: break
        }
    }
}

/// Remote folder status: host, last sync, errors; click for actions.
private struct RemoteBadge: View {
    @ObservedObject var session: RemoteSession
    var body: some View {
        Menu {
            Button("Pull from Server") { session.pull() }
            Button("Upload All to Server") { session.pushAll() }
            Button("Terminal on \(session.spec.host)") { session.terminal() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: session.syncing ? "arrow.triangle.2.circlepath" : session.status.isEmpty ? "network" : "exclamationmark.triangle")
                Text(session.spec.host)
                if let d = session.lastSync { Text(d, style: .relative).foregroundStyle(.secondary) }
            }
            .foregroundStyle(session.status.isEmpty ? Color.primary : Color.orange)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(session.status.isEmpty ? "Remote folder \(session.spec.title) — saves upload automatically" : session.status)
    }
}

enum PaneViewTypes { static let web: Set<String> = ["html", "htm", "xhtml", "css", "js", "mjs", "jsx", "ts", "tsx", "svg"] }

/// An icon button that shows whether its panel is on.
private struct ToggleButton: View {
    let icon: String
    let on: Bool
    let help: String
    let action: () -> Void
    @ObservedObject var theme = ThemeObserver.shared
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13))
                .frame(width: 28, height: 26)
                .foregroundStyle(on ? theme.palette.accent.swiftUI : Color.secondary)
                .background(on ? theme.palette.accent.swiftUI.opacity(0.14) : (hover ? Color.primary.opacity(0.07) : .clear), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).help(help).onHover { hover = $0 }
    }
}

/// The middle of the top bar: where you are (file path), what's happening (indexing, git, sync, a running task),
/// and a click target for Search Everywhere.
private struct CenterPill: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var lsp: LSPManager
    @ObservedObject var git: GitModel
    @ObservedObject var runner: RunManager
    @ObservedObject var theme = ThemeObserver.shared
    @State private var hover = false

    var body: some View {
        PillContent(ws: ws, assistant: ws.assistant, lsp: lsp, git: git, runner: runner)
    }
}

private struct PillContent: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var assistant: AssistantModel
    @ObservedObject var lsp: LSPManager
    @ObservedObject var git: GitModel
    @ObservedObject var runner: RunManager
    @State private var hover = false

    var body: some View {
        Button { ws.palette.open(.all) } label: {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11.5)).foregroundStyle(.secondary)
                if let d = ws.active {
                    let rel = ws.relative(d.url)
                    let parts = rel.split(separator: "/").map(String.init)
                    HStack(spacing: 3) {
                        if parts.count > 1 {
                            Text(parts.dropLast().suffix(2).joined(separator: " › ") + " ›").foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                        Image(systemName: FileIcon.symbol(d.url)).foregroundStyle(FileIcon.color(d.url)).font(.system(size: 11))
                        Text(d.name).fontWeight(.medium).lineLimit(1)
                        if d.isDirty { Circle().fill(Color.secondary).frame(width: 5, height: 5).help("Unsaved changes") }
                    }
                } else {
                    Text("Search files, symbols, actions, text and tasks").foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                activity
                Text("⇧⇧").font(.system(size: 10.5, design: .rounded)).foregroundStyle(.tertiary)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(minWidth: 240, idealWidth: 460, maxWidth: 560)
            .frame(height: 26)
            .background(Color.primary.opacity(hover ? 0.085 : 0.05), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Search Everywhere (⇧⇧)")
    }

    /// The most relevant thing in progress, if any.
    @ViewBuilder private var activity: some View {
        if let run = runner.runs.last(where: { $0.running }) {
            HStack(spacing: 4) { Circle().fill(Color.green).frame(width: 6, height: 6); Text(run.title).lineLimit(1) }
                .font(.system(size: 11)).foregroundStyle(.secondary).help("Running — open the Run panel with ⌘4")
        } else if let b = git.busy {
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text(b).lineLimit(1) }.font(.system(size: 11)).foregroundStyle(.secondary)
        } else if let p = lsp.progress {
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text(p).lineLimit(1) }.font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: 160)
        } else if assistant.busy {
            HStack(spacing: 4) { Image(systemName: "sparkles"); Text("AI working…") }.font(.system(size: 11)).foregroundStyle(.secondary)
        } else if let r = ws.remote, r.syncing {
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Syncing \(r.spec.host)") }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
