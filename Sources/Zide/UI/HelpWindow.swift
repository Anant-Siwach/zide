import AppKit
import SwiftUI

@MainActor
enum HelpWindow {
    enum Topic: String, CaseIterable, Identifiable {
        case start = "Getting Started", editing = "Editing", carets = "Multiple Carets", navigation = "Navigation",
             languages = "Languages & Completion", templates = "Live Templates", run = "Run & Debug", git = "Git & History",
             shortcuts = "Keyboard Shortcuts"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .start: "sparkles"
            case .editing: "text.cursor"
            case .carets: "cursorarrow.and.square.on.square.dashed"
            case .navigation: "location.magnifyingglass"
            case .languages: "chevron.left.forwardslash.chevron.right"
            case .templates: "text.badge.plus"
            case .run: "ladybug"
            case .git: "arrow.triangle.branch"
            case .shortcuts: "keyboard"
            }
        }
    }

    final class Nav: ObservableObject { @Published var topic: Topic = .start }
    private static let nav = Nav()
    private static var window: NSWindow?

    static func show(_ topic: Topic) {
        nav.topic = topic
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Zide Help"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: HelpView(nav: nav))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct HelpView: View {
    @ObservedObject var nav: HelpWindow.Nav

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<HelpWindow.Topic?>(get: { nav.topic }, set: { if let t = $0 { nav.topic = t } })) {
                ForEach(HelpWindow.Topic.allCases) { t in Label(t.rawValue, systemImage: t.icon).tag(t) }
            }
            .navigationSplitViewColumnWidth(210)
        } detail: {
            Group {
                switch nav.topic {
                case .shortcuts: ShortcutsHelp()
                case .templates: TemplatesHelp()
                default: ScrollView { HelpArticle(sections: HelpContent.sections(nav.topic)).padding(28) }
                }
            }
            .navigationTitle(nav.topic.rawValue)
        }
    }
}

private struct HelpArticle: View {
    let sections: [(String, [(String, String)])]
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(sections, id: \.0) { section in
                VStack(alignment: .leading, spacing: 10) {
                    Text(section.0).font(.title3.bold())
                    ForEach(section.1, id: \.0) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(item.0).font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundStyle(Color.accentColor).frame(width: 150, alignment: .leading)
                            Text((try? AttributedString(markdown: item.1)) ?? AttributedString(item.1)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .textSelection(.enabled)
    }
}

enum HelpContent {
    static func sections(_ t: HelpWindow.Topic) -> [(String, [(String, String)])] {
        switch t {
        case .start: return [
            ("Welcome to Zide", [
                ("Open a project", "**File › Open…** (⌘O), drag a folder onto the Dock icon, or run `zide .` in Terminal (install it from the Help menu)."),
                ("Find anything", "Press **⇧ twice** for Search Everywhere — files, symbols and actions. **⇧⌘A** finds any command."),
                ("Run & debug", "Pick a configuration in the top bar and press **▶** (⌃R) or the **bug** (⌃D). Click the gutter to add breakpoints."),
                ("Smart features", "Completion, errors, go to definition and rename come from each language's language server. Missing ones show an **Install** button in the status bar."),
                ("Saving", "Files save automatically a few seconds after you stop typing, when you switch windows, and before Run (like JetBrains)."),
            ]),
            ("Layout", [
                ("Tool windows", "The left stripe toggles Project (⌘1), Commit (⌘0), Structure (⌘7), Run (⌘4), Debug (⌘5), Terminal (⌥F12), Problems (⌘6), Find, TODO and Git Log (⌘9)."),
                ("Split editors", "**⌘\\\\** splits right (the same file in both panes), **⇧⌘\\\\** moves a tab to the other side, **⌃`** switches sides."),
                ("Hide everything", "**⇧⌘F12** hides all tool windows for a distraction-free editor."),
            ]),
        ]
        case .editing: return [
            ("Lines", [
                ("⌘D", "Duplicate the line or selection"), ("⌘⌫", "Delete line"), ("⌥⇧↑ / ⌥⇧↓", "Move line up / down"),
                ("⌘/", "Comment / uncomment"), ("⌥↑", "Extend selection (word → brackets → line → all)"), ("Tab / ⇧Tab", "Indent / outdent the selected lines"),
            ]),
            ("Folding", [
                ("⌘- / ⌘=", "Collapse / expand the block at the caret"), ("⇧⌘- / ⇧⌘=", "Collapse / expand all"),
                ("Gutter chevrons", "Click ⌄ next to a line number to fold; click the ⋯ placeholder to unfold."),
            ]),
            ("Smart typing", [
                ("Brackets & quotes", "Closing brackets and quotes are inserted for you; typing the closer steps over it. Return between brackets indents."),
                ("Inlay hints", "Grey labels show parameter names and inferred types (Settings › Editor to turn off)."),
                ("Local History", "Every save keeps a snapshot — **File › Local History** to compare or restore."),
                ("Find / Replace", "⌘F / ⌘R in the file, ⇧⌘F / ⇧⌘R across the project."),
            ]),
        ]
        case .carets: return [
            ("Adding carets", [
                ("⌥-click", "Add a caret (⌥-click an existing one to remove it)"), ("⌥-drag", "Column (rectangular) selection"),
                ("⌃G", "Select the word, then add the next occurrence"), ("⌃⌘G", "A caret on every occurrence"),
                ("⌥⌘↑ / ⌥⌘↓", "Add a caret on the line above / below"), ("Esc", "Back to a single caret"),
            ]),
            ("Editing with carets", [
                ("Typing", "Text, Backspace, Delete, Return and Tab apply at every caret."),
                ("Moving", "Arrows, ⌥-arrows (words) and ⌘-arrows (line ends) move every caret; add ⇧ to extend selections."),
                ("Clipboard", "Copy joins each caret's selection with newlines; pasting the same number of lines puts one at each caret."),
            ]),
        ]
        case .navigation: return [
            ("Jump", [
                ("⇧⇧", "Search Everywhere (Tab switches All / Files / Symbols / Actions)"), ("⇧⌘O", "Go to file — add `:42` to jump to a line"),
                ("⌥⌘O", "Go to symbol in the project"), ("⌘E", "Recent files"), ("⌘L", "Go to line:column"), ("⌘F12", "File structure"),
            ]),
            ("Code", [
                ("⌘B / ⌘-click", "Go to definition"), ("⌥F7", "Find usages"), ("F2 / ⇧F2", "Next / previous error"),
                ("⌘[ / ⌘]", "Back / forward"), ("F3 / ⌘F3", "Toggle bookmark / show bookmarks"),
            ]),
        ]
        case .languages: return [
            ("How language support works", [
                ("Everywhere", "Syntax colouring, search, run, terminal, folding, templates and Git work for ~55 languages with nothing installed."),
                ("Language servers", "Completion, errors, hover docs (or F1), go to definition, usages, rename (⇧F6), reformat (⌥⌘L), context actions (⌥↩) and inlay hints come from each language's server — the same ones VS Code uses."),
                ("Installing", "When a server is missing the status bar shows **Install …**; Settings › Languages lists every language and debugger with one-click install."),
            ]),
            ("Completion", [
                ("Automatic", "Suggestions appear as you type; ⌃Space asks explicitly. ↑↓ choose, Return / Tab accept, Esc closes."),
                ("Live templates", "Type an abbreviation such as `fori` or `iferr` and press **Tab** — then Tab jumps between the fields."),
                ("Paths", "Inside a string, typing `./`, `../` or `/` completes file and folder names."),
                ("Without a server", "Words from your open files and the language's keywords are suggested."),
            ]),
        ]
        case .run: return [
            ("Running", [
                ("⌃R", "Run the selected configuration (detected from Package.swift, package.json, Cargo.toml, go.mod, Makefile, …)"),
                ("⌃⇧R", "Run the current file"), ("Edit Configurations…", "Add your own commands from the run menu in the top bar."),
            ]),
            ("Debugging", [
                ("Breakpoints", "Click the gutter (or ⌘F8). Right-click a breakpoint to add a **condition** — it shows a ?."),
                ("⌃D", "Debug: Swift packages, Cargo, Go (Delve), single Swift/C/C++/Obj-C/Rust/Zig files, Python (debugpy), JavaScript and TypeScript (Node's built-in inspector)."),
                ("F8 / F7 / ⇧F8", "Step over / into / out"), ("⌥⌘R", "Resume"), ("⌘F2", "Stop"),
                ("Console", "Type an expression in the Debug console to evaluate it in the selected frame."),
            ]),
        ]
        case .git: return [
            ("Git", [
                ("Commit (⌘K)", "The Commit tool window lists changes with checkboxes; write a message and commit, or commit and push."),
                ("⇧⌘K / ⌘T", "Push / pull"), ("Branches", "Use the branch menu in the top bar to switch or create branches."),
                ("Gutter bars", "Green = added, blue = modified, ▸ = deleted lines since the last commit."),
                ("Blame", "The status bar shows who last changed the current line, and when."),
                ("Diffs", "Click a changed file in Commit to see its diff; right-click to roll back."),
            ]),
            ("Local History", [("Snapshots", "Zide keeps the last 50 saved versions of every file, even outside Git. File › Local History to compare and revert.")]),
        ]
        case .templates, .shortcuts: return []
        }
    }
}

private struct ShortcutsHelp: View {
    @State private var query = ""
    private var rows: [(menu: String, title: String, keys: String)] {
        var out: [(String, String, String)] = [("Editor", "Search Everywhere", "⇧⇧")]
        for top in NSApp.mainMenu?.items ?? [] {
            for item in top.submenu?.items ?? [] where !item.isSeparatorItem && !item.keyEquivalent.isEmpty {
                out.append((top.title, item.title, WorkspaceWindowController.shortcut(item)))
            }
        }
        out += [("Editor", "Add / remove caret", "⌥-click"), ("Editor", "Column selection", "⌥-drag"), ("Editor", "Go to definition", "⌘-click"),
                ("Editor", "Toggle breakpoint", "Click gutter"), ("Editor", "Expand live template / next field", "Tab")]
        return out.filter { query.isEmpty || $0.1.localizedCaseInsensitiveContains(query) || $0.0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search shortcuts", text: $query).textFieldStyle(.roundedBorder).padding(14)
            Table(rows.map { ShortcutRow(menu: $0.menu, title: $0.title, keys: $0.keys) }) {
                TableColumn("Action", value: \.title)
                TableColumn("Shortcut", value: \.keys).width(140)
                TableColumn("Menu", value: \.menu).width(110)
            }
        }
    }
}

private struct ShortcutRow: Identifiable {
    let id = UUID()
    let menu: String, title: String, keys: String
}

private struct TemplatesHelp: View {
    private let groups: [(String, [LiveTemplate])] = [
        ("Swift", LiveTemplates.swift), ("Python", LiveTemplates.python), ("JavaScript / TypeScript", LiveTemplates.js),
        ("Go", LiveTemplates.go), ("Rust", LiveTemplates.rust), ("C / C++", LiveTemplates.c), ("Java", LiveTemplates.java),
        ("Kotlin", LiveTemplates.kotlin), ("Shell", LiveTemplates.shell), ("HTML", LiveTemplates.html), ("Ruby", LiveTemplates.ruby), ("Markdown", LiveTemplates.markdown),
    ]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Type the abbreviation and press **Tab**. Tab again moves to the next field; Esc ends the template. Templates also appear in the completion list.")
                    .foregroundStyle(.secondary)
                ForEach(groups, id: \.0) { g in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(g.0).font(.headline)
                        ForEach(g.1, id: \.key) { t in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(t.key).font(.system(size: 12.5, weight: .semibold, design: .monospaced)).foregroundStyle(Color.accentColor).frame(width: 80, alignment: .leading)
                                Text(t.description).font(.system(size: 12.5)).frame(width: 180, alignment: .leading)
                                Text(Snippet.parse(t.body.replacingOccurrences(of: "\t", with: "  ")).text.replacingOccurrences(of: "\n", with: " ⏎ "))
                                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
