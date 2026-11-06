import AppKit

struct Diagnostic: Identifiable {
    enum Severity: Int { case error = 1, warning, info, hint }
    let id = UUID()
    let range: NSRange
    let line: Int
    let column: Int
    let severity: Severity
    let message: String
    let source: String?
}

/// Line-start table for fast offset ↔ (line, column) conversion.
struct LineIndex {
    private(set) var starts: [Int] = [0]
    let length: Int

    init(_ text: NSString) {
        length = text.length
        var starts = [0]
        starts.reserveCapacity(max(16, length / 30))
        var i = 0
        let buf = UnsafeMutablePointer<unichar>.allocate(capacity: 65536)
        defer { buf.deallocate() }
        while i < length {
            let chunk = min(65536, length - i)
            text.getCharacters(buf, range: NSRange(location: i, length: chunk))
            for k in 0..<chunk where buf[k] == 10 { starts.append(i + k + 1) }
            i += chunk
        }
        self.starts = starts
    }

    var lineCount: Int { starts.count }

    func line(of offset: Int) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func offset(line: Int, character: Int) -> Int {
        guard line < starts.count else { return length }
        let start = starts[max(0, line)]
        let end = line + 1 < starts.count ? starts[line + 1] - 1 : length
        return min(start + max(0, character), max(start, end))
    }

    func position(_ offset: Int) -> JSON {
        let l = line(of: offset)
        return ["line": l, "character": offset - starts[l]]
    }

    func range(_ lsp: JSON?) -> NSRange? {
        guard let lsp, let s = lsp["start"] as? JSON, let e = lsp["end"] as? JSON else { return nil }
        let a = offset(line: s["line"] as? Int ?? 0, character: s["character"] as? Int ?? 0)
        let b = offset(line: e["line"] as? Int ?? 0, character: e["character"] as? Int ?? 0)
        return NSRange(location: min(a, b), length: abs(b - a))
    }

    func lspRange(_ r: NSRange) -> JSON { ["start": position(r.location), "end": position(NSMaxRange(r))] }
}

/// An open file: its text, language, dirty state and diagnostics.
@MainActor
final class EditorDocument: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var url: URL
    @Published private(set) var language: Language
    @Published var isDirty = false
    @Published var diagnostics: [Diagnostic] = []
    @Published var cursorLine = 1
    @Published var cursorColumn = 1
    @Published var selectionLength = 0
    let storage = NSTextStorage()
    private(set) var version = 1
    private(set) var savedModDate: Date?
    private var cachedIndex: LineIndex?
    var lineEnding = "\n"
    /// Per-file soft wrap (⌥Z); nil = automatic.
    var softWrap: Bool?
    var encoding: String.Encoding = .utf8
    var isPreview = false
    var isBinary = false
    var isTooLarge: Bool { storage.length > 3_000_000 }

    /// Indentation found in the file itself (nil = too little to tell; the setting applies).
    var detectedIndent: (spaces: Bool, width: Int)?
    var insertSpaces: Bool { detectedIndent?.spaces ?? Prefs.shared.insertSpaces }
    var tabWidth: Int { detectedIndent.map { $0.spaces ? $0.width : Prefs.shared.tabWidth } ?? Prefs.shared.tabWidth }
    var indentUnit: String { insertSpaces ? String(repeating: " ", count: max(1, tabWidth)) : "\t" }

    /// Looks at the first few thousand lines: tabs vs spaces, and the most common step between indent levels.
    static func detectIndent(_ text: NSString) -> (spaces: Bool, width: Int)? {
        var tabs = 0, spaces = 0, prev = 0
        var steps: [Int: Int] = [:]
        var lines = 0
        text.enumerateLines { line, stop in
            lines += 1
            if lines > 4000 { stop.pointee = true; return }
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            if line.hasPrefix("\t") { tabs += 1; return }
            let n = line.prefix { $0 == " " }.count
            if n > 0 { spaces += 1 }
            let d = abs(n - prev)
            if d >= 2 && d <= 8 { steps[d, default: 0] += 1 }
            prev = n
        }
        guard tabs + spaces >= 5 else { return nil }
        if tabs > spaces { return (false, Prefs.shared.tabWidth) }
        // Prefer the smallest common step (2-space files also have 4-space jumps).
        let total = steps.values.reduce(0, +)
        for w in [2, 3, 4, 8] where Double(steps[w] ?? 0) >= Double(total) * 0.25 { return (true, w) }
        return steps.max { $0.value < $1.value }.map { (true, $0.key) }
    }
    weak var workspace: Workspace?
    private var primary: EditorController?
    private(set) var secondary: EditorController?

    /// The editor for pane 0 (always exists once the document is shown).
    var primaryEditor: EditorController {
        if let primary { return primary }
        let e = EditorController(document: self, pane: 0)
        primary = e
        return e
    }

    /// Each split pane gets its own text view over the shared text storage.
    func editor(pane: Int) -> EditorController {
        if pane == 0 { return primaryEditor }
        if let secondary { return secondary }
        let e = EditorController(document: self, pane: 1)
        secondary = e
        return e
    }

    /// The editor the user is looking at (the focused pane's, if it shows this document).
    var editor: EditorController { editor(pane: workspace?.pane(showing: self) ?? 0) }
    var editors: [EditorController] { [primaryEditor] + (secondary.map { [$0] } ?? []) }

    func dropSecondary() {
        guard let s = secondary else { return }
        s.teardown()
        secondary = nil
    }

    var text: String { storage.string }
    var uri: String { url.absoluteString }
    var name: String { url.lastPathComponent }
    var lineIndex: LineIndex {
        if let cachedIndex { return cachedIndex }
        let idx = LineIndex(storage.string as NSString)
        cachedIndex = idx
        return idx
    }

    init(url: URL) {
        self.url = url
        self.language = .plainText
        load()
    }

    func load() {
        let t0 = Date()
        defer { if ProcessInfo.processInfo.environment["ZIDE_TRACE"] != nil { print(String(format: "load %@ %.0f ms", url.lastPathComponent, Date().timeIntervalSince(t0) * 1000)) } }
        if url.mediaKind != nil || url.isDatabase {
            // Shown by the image/PDF viewer or the database browser; no need to read it as text.
            isBinary = true
            setText("")
            return
        }
        guard let data = try? Data(contentsOf: url) else { return }
        if data.prefix(8000).contains(0) {
            isBinary = true
            setText("(Binary file — \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))")
        } else {
            // NSString and a byte scan: Swift's grapheme-aware String search took over a second on a 40 MB log.
            var ns = NSString(data: data, encoding: String.Encoding.utf8.rawValue)
            if ns == nil { ns = NSString(data: data, encoding: String.Encoding.isoLatin1.rawValue); encoding = .isoLatin1 }
            let hasCRLF = data.range(of: Data([13, 10])) != nil
            if hasCRLF { lineEnding = "\r\n" }
            let text = (ns ?? "") as NSString
            setText(hasCRLF ? text.replacingOccurrences(of: "\r\n", with: "\n") : text as String)
        }
        savedModDate = modDate()
        detectedIndent = isTooLarge ? nil : Self.detectIndent(storage.string as NSString)
        let first = storage.string.prefix(200).split(separator: "\n", maxSplits: 1).first.map(String.init)
        language = Language.detect(url, firstLine: first)
        isDirty = false
    }

    private func setText(_ s: String) {
        let t0 = Date()
        defer { if ProcessInfo.processInfo.environment["ZIDE_TRACE"] != nil { print(String(format: "  setText %.0f ms", Date().timeIntervalSince(t0) * 1000)) } }
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: s)
        storage.setAttributes([.font: Prefs.shared.editorFont, .foregroundColor: Theme.current.text], range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        textChanged()
    }

    func modDate() -> Date? { (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date }

    /// Called after every edit.
    func textChanged() {
        version += 1
        cachedIndex = nil
    }

    func markEdited() {
        textChanged()
        if !isDirty { isDirty = true }
        workspace?.documentEdited(self)
    }

    /// Strips trailing spaces (except on the caret line, so typing isn't disturbed) and ensures a final newline.
    func tidyBeforeSave() {
        guard Prefs.shared.trimWhitespace, !isBinary, !isTooLarge, language.lexer != .markdown, language.lexer != .diff else { return }
        let ns = storage.string as NSString
        let caretLine = lineIndex.line(of: editor.textView.selectedRange().location)
        var edits: [(NSRange, String)] = []
        let idx = lineIndex
        for line in 0..<idx.lineCount where line != caretLine {
            let start = idx.starts[line]
            var end = line + 1 < idx.lineCount ? idx.starts[line + 1] - 1 : ns.length
            let contentEnd = end
            while end > start, ns.character(at: end - 1) == 32 || ns.character(at: end - 1) == 9 { end -= 1 }
            if end < contentEnd { edits.append((NSRange(location: end, length: contentEnd - end), "")) }
        }
        if ns.length > 0 && ns.character(at: ns.length - 1) != 10 { edits.append((NSRange(location: ns.length, length: 0), "\n")) }
        if !edits.isEmpty { editor.replace(edits) }
    }

    @discardableResult
    func save() -> Bool {
        guard !isBinary else { return false }
        // Notebooks are JSON written by Zide itself: nothing to tidy (and their editor isn't on screen).
        if isDirty && url.pathExtension.lowercased() != "ipynb" { tidyBeforeSave() }
        var out = storage.string
        if lineEnding == "\r\n" { out = out.replacingOccurrences(of: "\n", with: "\r\n") }
        do {
            try out.data(using: encoding, allowLossyConversion: true)?.write(to: url, options: .atomic)
            savedModDate = modDate()
            isDirty = false
            workspace?.documentSaved(self)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    /// Reloads from disk if it changed externally and has no unsaved edits.
    func reloadIfChangedOnDisk() {
        guard let d = modDate(), d != savedModDate else { return }
        if isDirty { return }
        let sel = editor.textView.selectedRange()
        let atEnd = sel.location >= storage.length - 1
        load()
        // Like `tail -f`: a caret at the end of a growing file follows it.
        if atEnd && Prefs.shared.followLogs {
            editor.textView.setSelectedRange(NSRange(location: storage.length, length: 0))
            editor.textView.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
        } else {
            editor.textView.setSelectedRange(NSRange(location: min(sel.location, storage.length), length: 0))
        }
        editors.forEach { $0.rehighlight() }
        workspace?.lsp.didChange(self)
    }

    func rename(to newURL: URL) {
        workspace?.lsp.didClose(self)
        url = newURL
        let first = storage.string.prefix(200).split(separator: "\n", maxSplits: 1).first.map(String.init)
        language = Language.detect(newURL, firstLine: first)
        editors.forEach { $0.rehighlight() }
        workspace?.lsp.didOpen(self)
    }

    /// Applies LSP TextEdits (back to front so offsets stay valid) as one undoable change.
    func apply(edits: [JSON]) {
        let idx = lineIndex
        let ranges: [(NSRange, String)] = edits.compactMap { e in
            guard let r = idx.range(e["range"] as? JSON) else { return nil }
            return (r, e["newText"] as? String ?? "")
        }.sorted { $0.0.location > $1.0.location }
        guard !ranges.isEmpty else { return }
        editor.replace(ranges)
    }
}
