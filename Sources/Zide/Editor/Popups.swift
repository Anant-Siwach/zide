import AppKit
import SwiftUI

enum SymbolKind {
    /// SF Symbol for an LSP SymbolKind / CompletionItemKind.
    static func icon(_ kind: Int) -> String {
        switch kind {
        case 2, 9: return "shippingbox"            // module, namespace
        case 5, 7: return "c.square"               // class
        case 6: return "m.square"                  // method
        case 8, 10: return "f.square"              // field, enum? (symbol 8 field)
        case 11: return "i.square"                 // interface
        case 12: return "f.cursive"                // function
        case 13: return "v.square"                 // variable
        case 14: return "k.square"                 // constant
        case 22, 23: return "s.square"             // enum member, struct
        case 26: return "t.square"                 // type parameter
        default: return "chevron.left.forwardslash.chevron.right"
        }
    }

    static func completionIcon(_ kind: Int) -> (String, Color) {
        switch kind {
        case 2, 3, 4: return ("f.square.fill", .purple)       // method, function, constructor
        case 5, 10: return ("p.square.fill", .orange)         // field, property
        case 6: return ("v.square.fill", .blue)               // variable
        case 7, 22: return ("c.square.fill", .teal)           // class, struct
        case 8: return ("i.square.fill", .green)              // interface
        case 9: return ("shippingbox.fill", .brown)           // module
        case 13, 20: return ("e.square.fill", .yellow)        // enum, enum member
        case 14: return ("k.square.fill", .pink)              // keyword
        case 15: return ("curlybraces.square.fill", .gray)    // snippet
        case 17: return ("doc.fill", .gray)                   // file
        case 21: return ("c.square.fill", .indigo)            // constant
        case 25: return ("t.square.fill", .mint)              // type parameter
        default: return ("text.alignleft", .secondary)
        }
    }
}

struct CompletionItem: Identifiable {
    let id = UUID()
    let label: String
    let detail: String
    let kind: Int
    let filter: String
    let sort: String
    let insert: String
    let isSnippet: Bool
    let editRange: JSON?
    let raw: JSON?
    var documentation: String
    var score = 0
    var isTemplate = false
    var replaceStart: Int? = nil   // path completion: start of the file-name fragment
}

// MARK: - Completion

@MainActor
final class CompletionController: ObservableObject {
    unowned let editor: EditorController
    @Published var items: [CompletionItem] = []
    @Published var selected = 0
    @Published var docText = ""
    private var all: [CompletionItem] = []
    private var panel: NSPanel?
    private var anchor = 0          // start of the word being completed
    private var requestID = 0
    private(set) var isVisible = false
    private var debounce: Timer?
    static let docHeight: CGFloat = 96

    init(editor: EditorController) { self.editor = editor }

    func trigger(manual: Bool, char: String? = nil) {
        debounce?.invalidate()
        let delay = manual || char != nil ? 0 : 0.08
        debounce = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.request(manual: manual, char: char) }
        }
    }

    private func request(manual: Bool, char: String?) {
        guard let doc = editor.document, let ws = editor.workspace else { return }
        let caret = editor.textView.selectedRange().location
        let word = editor.wordRange(at: caret)
        anchor = word.location
        let prefixLength = caret - word.location
        if let t = editor.token(at: max(0, caret - 1)), t.kind == .comment || (t.kind == .string && char == nil && !manual) { hide(); return }
        if let path = pathCompletions(caret: caret) {
            anchor = path.anchor
            requestID += 1
            all = path.items
            refilter()
            return
        }
        let hasServer = ws.lsp.client(of: doc)?.supports("completionProvider") == true
        if !manual && char == nil && prefixLength < (hasServer ? 1 : 3) { hide(); return }
        requestID += 1
        let id = requestID
        guard hasServer else {
            all = wordCompletions(prefixLength: prefixLength) + templateItems()
            refilter()
            return
        }
        var context: JSON = ["triggerKind": char != nil ? 2 : 1]
        if let char { context["triggerCharacter"] = char }
        Task {
            let r = await ws.lsp.request("textDocument/completion", doc, offset: caret, extra: ["context": context])
            guard id == self.requestID else { return }
            let list = (r as? [JSON]) ?? ((r as? JSON)?["items"] as? [JSON]) ?? []
            self.all = list.prefix(2000).map(Self.item) + (char == nil ? self.templateItems() : [])
            if self.all.isEmpty && !manual { self.all = self.wordCompletions(prefixLength: prefixLength) }
            self.refilter()
        }
    }

    private static func item(_ d: JSON) -> CompletionItem {
        let label = d["label"] as? String ?? ""
        let details = d["labelDetails"] as? JSON
        let detail = [d["detail"] as? String, details?["detail"] as? String, details?["description"] as? String].compactMap { $0 }.first ?? ""
        let edit = d["textEdit"] as? JSON
        let insert = (edit?["newText"] as? String) ?? (d["insertText"] as? String) ?? label
        return CompletionItem(label: label, detail: detail, kind: d["kind"] as? Int ?? 1,
                              filter: d["filterText"] as? String ?? label, sort: d["sortText"] as? String ?? label,
                              insert: insert, isSnippet: (d["insertTextFormat"] as? Int) == 2,
                              editRange: (edit?["range"] as? JSON) ?? (edit?["replace"] as? JSON), raw: d,
                              documentation: LSP.markdown(d["documentation"]))
    }

    private func templateItems() -> [CompletionItem] {
        guard let lang = editor.document?.language else { return [] }
        return LiveTemplates.templates(for: lang).map {
            CompletionItem(label: $0.key, detail: $0.description + " (template)", kind: 15, filter: $0.key, sort: "~~" + $0.key,
                           insert: $0.body, isSnippet: true, editRange: nil, raw: nil, documentation: $0.body.replacingOccurrences(of: "\t", with: "    "), isTemplate: true)
        }
    }

    /// Inside a string that looks like a path: complete file and folder names.
    private func pathCompletions(caret: Int) -> (anchor: Int, items: [CompletionItem])? {
        guard let doc = editor.document, caret > 0, let t = editor.token(at: caret - 1), t.kind == .string else { return nil }
        let ns = editor.textView.string as NSString
        let start = Int(t.start) + 1
        guard caret >= start else { return nil }
        let typed = ns.substring(with: NSRange(location: start, length: caret - start))
        guard typed.hasPrefix("./") || typed.hasPrefix("../") || typed.hasPrefix("/") || typed.hasPrefix("~/") || (typed.contains("/") && !typed.contains(" ") && !typed.contains("://")) else { return nil }
        let slash = (typed as NSString).range(of: "/", options: .backwards)
        let dirPart = (typed as NSString).substring(to: slash.location + 1)
        let base: URL
        if dirPart.hasPrefix("/") { base = URL(fileURLWithPath: dirPart) }
        else if dirPart.hasPrefix("~/") { base = URL(fileURLWithPath: (dirPart as NSString).expandingTildeInPath) }
        else {
            let rel = doc.url.deletingLastPathComponent().appendingPathComponent(dirPart)
            base = FileManager.default.fileExists(atPath: rel.path) ? rel : (doc.workspace?.root.appendingPathComponent(dirPart) ?? rel)
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return nil }
        let items = entries.prefix(500).filter { $0.lastPathComponent != ".DS_Store" }.map { u -> CompletionItem in
            let dir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let name = u.lastPathComponent + (dir ? "/" : "")
            return CompletionItem(label: name, detail: dir ? "folder" : "file", kind: dir ? 19 : 17, filter: u.lastPathComponent, sort: (dir ? "0" : "1") + name,
                                  insert: name, isSnippet: false, editRange: nil, raw: nil, documentation: "")
        }
        return (start + slash.location + 1, items)
    }

    /// Without a language server: words from open files + language keywords.
    private func wordCompletions(prefixLength: Int) -> [CompletionItem] {
        guard let doc = editor.document else { return [] }
        var words = Set<String>()
        let caretWord = editor.wordRange(at: editor.textView.selectedRange().location)
        let sources = [doc] + (doc.workspace?.documents.filter { $0 !== doc }.prefix(12) ?? [])
        for source in sources {
            let ns = source.storage.string as NSString
            let scanLimit = min(ns.length, 300_000)
            var i = 0, start = -1
            while i <= scanLimit {
                let c: unichar = i < scanLimit ? ns.character(at: i) : 32
                if EditorController.isIdent(c) { if start < 0 { start = i } } else if start >= 0 {
                    if i - start >= 3, !(source === doc && start == caretWord.location) { words.insert(ns.substring(with: NSRange(location: start, length: i - start))) }
                    start = -1
                }
                i += 1
            }
        }
        let kws = doc.language.keywords.union(doc.language.builtins).union(doc.language.types)
        return words.subtracting(kws).map { CompletionItem(label: $0, detail: "", kind: 1, filter: $0, sort: $0, insert: $0, isSnippet: false, editRange: nil, raw: nil, documentation: "") }
            + kws.map { CompletionItem(label: $0, detail: "keyword", kind: 14, filter: $0, sort: "~" + $0, insert: $0, isSnippet: false, editRange: nil, raw: nil, documentation: "") }
    }

    func refilter() {
        let caret = editor.textView.selectedRange().location
        let ns = editor.textView.string as NSString
        guard caret >= anchor, caret <= ns.length else { hide(); return }
        let prefix = ns.substring(with: NSRange(location: anchor, length: caret - anchor)).lowercased()
        var scored: [CompletionItem] = []
        for var item in all {
            guard let s = Self.fuzzy(prefix, item.filter.lowercased()) else { continue }
            item.score = s
            scored.append(item)
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : ($0.sort != $1.sort ? $0.sort < $1.sort : $0.label.count < $1.label.count) }
        items = Array(scored.prefix(200))
        if items.count == 1 && items[0].label.lowercased() == prefix && !prefix.isEmpty { hide(); return }
        selected = 0
        if items.isEmpty { hide() } else { show(); updateDoc() }
    }

    /// Prefix matches beat camel-hump matches beat subsequences.
    static func fuzzy(_ q: String, _ s: String) -> Int? {
        if q.isEmpty { return 1 }
        if s.hasPrefix(q) { return 1000 - s.count }
        var score = 0, si = s.startIndex
        for qc in q {
            guard let found = s[si...].firstIndex(of: qc) else { return nil }
            score += found == si ? 10 : 1
            si = s.index(after: found)
        }
        return score
    }

    func move(_ d: Int) {
        guard !items.isEmpty else { return }
        selected = max(0, min(items.count - 1, selected + d))
        updateDoc()
    }

    private func setDoc(_ text: String) {
        let changedShape = text.isEmpty != docText.isEmpty
        docText = text
        if changedShape && isVisible { show() }
    }

    private func updateDoc() {
        guard items.indices.contains(selected) else { setDoc(""); return }
        let item = items[selected]
        setDoc(item.documentation)
        // Resolve documentation lazily.
        guard item.documentation.isEmpty, let raw = item.raw, let doc = editor.document,
              let c = editor.workspace?.lsp.client(of: doc),
              ((c.capabilities["completionProvider"] as? JSON)?["resolveProvider"] as? Bool) == true else { return }
        let id = item.id
        c.request("completionItem/resolve", raw) { [weak self] result in
            guard let self, case .success(let r) = result, let d = r as? JSON else { return }
            if let idx = self.items.firstIndex(where: { $0.id == id }) {
                self.items[idx].documentation = LSP.markdown(d["documentation"])
                if self.items.indices.contains(self.selected), self.items[self.selected].id == id { self.setDoc(self.items[idx].documentation) }
            }
        }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 125: move(1); return true
        case 126: move(-1); return true
        case 36, 76, 48: accept(); return true
        case 53: hide(); return true
        default: return false
        }
    }

    func caretMoved() {
        let caret = editor.textView.selectedRange().location
        if caret < anchor { hide() }
    }

    func accept() {
        guard items.indices.contains(selected), let doc = editor.document else { hide(); return }
        let item = items[selected]
        let tv = editor.textView
        let caret = tv.selectedRange().location
        var range = NSRange(location: anchor, length: caret - anchor)
        if let r = doc.lineIndex.range(item.editRange) { range = NSRange(location: r.location, length: max(r.length, caret - r.location)) }
        if item.isSnippet {
            tv.insertSnippet(item.insert, replacing: range)
        } else {
            tv.replace(range, with: item.insert, select: NSRange(location: range.location + (item.insert as NSString).length, length: 0))
        }
        if let extra = item.raw?["additionalTextEdits"] as? [JSON], !extra.isEmpty { doc.apply(edits: extra) }
        hide()
        if item.kind == 19 { trigger(manual: true) }          // keep completing inside the folder
        if !item.isTemplate && item.insert.contains("(") { editor.signatureHelp() }
    }

    private func show() {
        let tv = editor.textView
        guard let window = tv.window else { return }
        let rect = tv.firstRect(forCharacterRange: NSRange(location: anchor, length: 0), actualRange: nil)
        let panel = self.panel ?? makePanel()
        let rows = CGFloat(min(items.count, 10))
        let height = rows * 24 + 8 + (docText.isEmpty ? 0 : Self.docHeight + 1)
        var frame = NSRect(x: rect.minX - 28, y: rect.minY - height - 2, width: 460, height: height)
        if let screen = window.screen, frame.minY < screen.visibleFrame.minY { frame.origin.y = rect.maxY + 2 }
        panel.setFrame(frame, display: true)
        if !isVisible {
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
            isVisible = true
        }
    }

    func hide() {
        debounce?.invalidate()
        requestID += 1
        guard isVisible, let panel else { isVisible = false; return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        isVisible = false
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.contentView = NSHostingView(rootView: CompletionView(model: self))
        panel = p
        return p
    }
}

private struct CompletionView: View {
    @ObservedObject var model: CompletionController
    @ObservedObject var theme = ThemeObserver.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                            row(item, selected: i == model.selected)
                                .id(i)
                                .onTapGesture { model.selected = i; model.accept() }
                        }
                    }
                    .padding(4)
                }
                .onChange(of: model.selected) { _, s in proxy.scrollTo(s) }
            }
            if !model.docText.isEmpty {
                Divider()
                ScrollView {
                    Text(model.docText.replacingOccurrences(of: "```", with: ""))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: CompletionController.docHeight)
            }
        }
        .background(theme.palette.panel.swiftUI)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
    }

    private func row(_ item: CompletionItem, selected: Bool) -> some View {
        let (icon, color) = SymbolKind.completionIcon(item.kind)
        return HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 12))
            Text(item.label).font(.system(size: 12.5, design: .monospaced)).lineLimit(1)
            Spacer(minLength: 8)
            Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(selected ? theme.palette.accent.swiftUI.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
    }
}

// MARK: - Hover / quick docs / signature

@MainActor
final class InfoPopup {
    unowned let editor: EditorController
    private var panel: NSPanel?
    private var hosting: NSHostingView<MarkdownView>?
    private(set) var isVisible = false
    private var isHover = false
    private var isSignature = false
    private var line = -1

    init(editor: EditorController) { self.editor = editor }

    func show(markdown: String, at offset: Int, isHover: Bool) {
        present(markdown, at: offset, above: false)
        self.isHover = isHover
        isSignature = false
    }

    func showSignature(markdown: String, at offset: Int) {
        present(markdown, at: offset, above: true)
        isHover = false
        isSignature = true
    }

    private func present(_ md: String, at offset: Int, above: Bool) {
        let tv = editor.textView
        guard let window = tv.window else { return }
        let panel = self.panel ?? makePanel()
        hosting?.rootView = MarkdownView(text: md)
        let size = hosting?.fittingSize ?? NSSize(width: 400, height: 100)
        let w = min(max(size.width, 220), 620), h = min(size.height, 380)
        let rect = tv.firstRect(forCharacterRange: NSRange(location: offset, length: 0), actualRange: nil)
        var frame = NSRect(x: rect.minX - 8, y: above ? rect.maxY + 4 : rect.minY - h - 4, width: w, height: h)
        if let screen = window.screen {
            if frame.minY < screen.visibleFrame.minY { frame.origin.y = rect.maxY + 4 }
            if frame.maxX > screen.visibleFrame.maxX { frame.origin.x = screen.visibleFrame.maxX - w - 8 }
        }
        panel.setFrame(frame, display: true)
        if !isVisible { window.addChildWindow(panel, ordered: .above); panel.orderFront(nil) }
        isVisible = true
        line = editor.document?.lineIndex.line(of: offset) ?? -1
    }

    func hide() {
        guard isVisible, let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        isVisible = false
    }

    func hideIfHover() { if isHover { hide() } }
    func hideSignature() { if isSignature { hide() } }

    func caretMoved() {
        guard isVisible, !isHover, let doc = editor.document else { return }
        if doc.lineIndex.line(of: editor.textView.selectedRange().location) != line { hide() }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        let h = NSHostingView(rootView: MarkdownView(text: ""))
        p.contentView = h
        hosting = h
        panel = p
        return p
    }
}

/// Renders LSP markdown: fenced code blocks in monospace, everything else as inline markdown.
struct MarkdownView: View {
    let text: String
    @ObservedObject var theme = ThemeObserver.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    if block.code {
                        Text(block.text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(theme.palette.text.swiftUI)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if block.text == "---" {
                        Divider()
                    } else {
                        Text((try? AttributedString(markdown: block.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(block.text))
                            .font(.system(size: 12.5))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: 600, alignment: .leading)
        }
        .frame(minWidth: 200, maxWidth: 620)
        .fixedSize(horizontal: false, vertical: true)
        .background(theme.palette.panel.swiftUI)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
    }

    private var blocks: [(code: Bool, text: String)] {
        var out: [(Bool, String)] = []
        var current: [String] = []
        var inCode = false
        func flush() {
            let t = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append((inCode, t)) }
            current = []
        }
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush(); inCode.toggle(); continue
            }
            if !inCode && line.trimmingCharacters(in: .whitespaces) == "---" { flush(); out.append((false, "---")); continue }
            current.append(line)
        }
        flush()
        return out.isEmpty ? [(false, " ")] : out
    }
}
