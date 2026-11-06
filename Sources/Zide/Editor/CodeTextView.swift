import AppKit

/// The code editing surface: JetBrains-style editing actions on top of NSTextView.
final class CodeTextView: NSTextView {
    weak var controller: EditorController?
    var extraCursors: [NSRange] = []
    var isSettingCursors = false
    var inMultiEdit = false
    var snippetStops: [NSRange] = []
    private var hoverTimer: Timer?
    private var hoverPoint: NSPoint = .zero
    private var trackingAreaRef: NSTrackingArea?

    var prefs: Prefs { Prefs.shared }
    /// The file's own indentation when it has one, else the setting.
    var indentUnit: String { controller?.document?.indentUnit ?? Prefs.shared.indentUnit }
    var tabWidth: Int { controller?.document?.tabWidth ?? Prefs.shared.tabWidth }
    var insertSpaces: Bool { controller?.document?.insertSpaces ?? Prefs.shared.insertSpaces }
    var lang: Language { controller?.document?.language ?? .plainText }
    private var ns: NSString { string as NSString }

    // MARK: Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lm = layoutManager, let tc = textContainer else { return }
        let palette = Theme.current
        // Debugger execution point
        if let line = controller?.executionLine, let doc = controller?.document {
            let off = doc.lineIndex.offset(line: line - 1, character: 0)
            let r = lineFragmentRect(at: off)
            (Theme.isDark ? Palette.hex("2D4B73") : Palette.hex("C9DCFF")).setFill()
            NSRect(x: 0, y: r.minY, width: bounds.width, height: r.height).intersection(rect).fill()
        }
        drawExtraSelections(in: rect)
        controller?.drawFoldPlaceholders(in: rect)
        // Current line
        let sel = selectedRange()
        if sel.length == 0 && controller?.executionLine == nil {
            let lineRect = lineFragmentRect(at: sel.location)
            palette.currentLine.setFill()
            NSRect(x: 0, y: lineRect.minY, width: bounds.width, height: lineRect.height).intersection(rect).fill()
        }
        // Indent guides
        guard prefs.showMinimapGuides, lang.lexer != .plain, lang.lexer != .markdown else { return }
        let space = (" " as NSString).size(withAttributes: [.font: font ?? prefs.editorFont]).width
        let unit = CGFloat(max(1, tabWidth)) * space
        let glyphs = lm.glyphRange(forBoundingRect: rect, in: tc)
        palette.indentGuide.setFill()
        lm.enumerateLineFragments(forGlyphRange: glyphs) { frag, _, _, gr, _ in
            let cr = lm.characterRange(forGlyphRange: gr, actualGlyphRange: nil)
            let line = self.ns.lineRange(for: NSRange(location: cr.location, length: 0))
            guard line.location == cr.location else { return } // first fragment of a line only
            var indent: CGFloat = 0, i = line.location
            let end = NSMaxRange(line)
            var blank = true
            while i < end {
                let c = self.ns.character(at: i)
                if c == 32 { indent += space } else if c == 9 { indent += unit } else { blank = c == 10; break }
                i += 1
            }
            if blank { return }
            var x = unit
            while x < indent - 1 {
                NSRect(x: self.textContainerOrigin.x + x + 2, y: frag.minY, width: 1, height: frag.height).fill()
                x += unit
            }
        }
    }

    private func lineFragmentRect(at loc: Int) -> NSRect {
        guard let lm = layoutManager, let tc = textContainer else { return .zero }
        if loc >= ns.length, ns.length > 0, ns.character(at: ns.length - 1) != 10 || lm.extraLineFragmentRect.isEmpty {
            let g = lm.glyphIndexForCharacter(at: max(0, ns.length - 1))
            return lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).offsetBy(dx: 0, dy: textContainerOrigin.y)
        }
        if loc >= ns.length { return lm.extraLineFragmentRect.offsetBy(dx: 0, dy: textContainerOrigin.y) }
        _ = tc
        let g = lm.glyphIndexForCharacter(at: loc)
        return lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).offsetBy(dx: 0, dy: textContainerOrigin.y)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawWhitespace(in: dirtyRect)
        drawInlayHints(in: dirtyRect)
        drawExtraCarets(in: dirtyRect)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { controller?.didFocus() }
        return ok
    }

    override func doCommand(by selector: Selector) {
        if hasMultipleCursors {
            if let c = controller, c.completion.isVisible { c.completion.hide() }
            if handleMultiCommand(selector) { return }
            clearExtraCursors()
        }
        super.doCommand(by: selector)
    }

    override func didChangeText() {
        super.didChangeText()
        if !inMultiEdit && hasMultipleCursors { clearExtraCursors() }
    }

    /// Keeps breakpoints and bookmarks on their lines when lines are added or removed above them.
    override func shouldChangeText(in range: NSRange, replacementString: String?) -> Bool {
        guard super.shouldChangeText(in: range, replacementString: replacementString) else { return false }
        controller?.textWillChange(range, replacementLength: ((replacementString ?? "") as NSString).length)
        adjustSnippetStops(range, replacementLength: ((replacementString ?? "") as NSString).length)
        let ns = string as NSString
        guard NSMaxRange(range) <= ns.length else { return true }
        let old = ns.substring(with: range)
        let oldLines = old.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        let newLines = (replacementString ?? "").reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        if oldLines != newLines, let doc = controller?.document {
            let startLine = doc.lineIndex.line(of: range.location) + 1
            controller?.linesChanged(startLine: startLine, delta: newLines - oldLines,
                                     removed: oldLines > 0 ? (startLine...(startLine + oldLines)) : nil)
        }
        return true
    }

    override func copy(_ sender: Any?) {
        guard hasMultipleCursors else { super.copy(sender); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(multiCopyText(), forType: .string)
    }

    override func cut(_ sender: Any?) {
        guard hasMultipleCursors else { super.cut(sender); return }
        copy(sender)
        editAll { r in r.length > 0 ? (r, "", nil) : nil }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        if hasMultipleCursors && !isSettingCursors && !inMultiEdit && !stillSelecting && ranges.count == 1 { extraCursors = []; needsDisplay = true }
        let old = selectedRange()
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if old.location != selectedRange().location || old.length != selectedRange().length {
            needsDisplay = true // repaint current-line highlight
        }
    }

    // MARK: Keys

    /// AI ghost-text suggestion at the caret.
    lazy var ghost = GhostText(self)

    override func keyDown(with event: NSEvent) {
        hideHover()
        // Tab is handled in insertTab; any other key dismisses the suggestion.
        if ghost.isVisible && event.keyCode != 48 { ghost.hide() }
        if let c = controller, c.completion.isVisible, c.completion.handleKey(event) { return }
        if event.keyCode == 53 { // esc
            controller?.info.hide()
            snippetStops = []
        }
        adoptNativeMultiSelection()
        super.keyDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let s = (string as? String) ?? (string as? NSAttributedString)?.string else {
            super.insertText(string, replacementRange: replacementRange); return
        }
        if hasMultipleCursors && replacementRange.location == NSNotFound { multiInsert(s); return }
        let sel = selectedRange()
        if prefs.autoClosePairs, s.count == 1, replacementRange.location == NSNotFound, let ch = s.first, handlePair(ch, sel) { return }
        if replacementRange.location == NSNotFound, autoCloseTag(s, sel) { return }
        super.insertText(string, replacementRange: replacementRange)
        controller?.typed(s)
        if replacementRange.location == NSNotFound && !hasMultipleCursors { ghost.typed() }
    }

    private static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"]
    private static let closers: Set<Character> = [")", "]", "}", "\"", "'", "`"]

    private func handlePair(_ ch: Character, _ sel: NSRange) -> Bool {
        let next: Character? = NSMaxRange(sel) < ns.length ? Character(UnicodeScalar(ns.character(at: NSMaxRange(sel))) ?? " ") : nil
        let prev: Character? = sel.location > 0 ? Character(UnicodeScalar(ns.character(at: sel.location - 1)) ?? " ") : nil
        // Typing a closer right before the same closer just steps over it.
        if Self.closers.contains(ch), sel.length == 0, next == ch {
            setSelectedRange(NSRange(location: sel.location + 1, length: 0))
            return true
        }
        guard let close = Self.pairs[ch] else { return false }
        let isQuote = ch == "\"" || ch == "'" || ch == "`"
        if isQuote {
            if lang.lexer == .plain || lang.lexer == .markdown { return false }
            if ch == "'" && (lang.id == "rust" || lang.lexer == .yaml) { return false }
            if let prev, prev.isLetter || prev.isNumber || prev == "\\" { return false }
            if ch == "`" && !lang.strings.contains("`") { return false }
        }
        // Wrap a selection in the pair.
        if sel.length > 0 {
            let inner = ns.substring(with: sel)
            insertText("\(ch)\(inner)\(close)", replacementRange: sel)
            setSelectedRange(NSRange(location: sel.location + 1, length: (inner as NSString).length))
            return true
        }
        if let next, !(next.isWhitespace || Self.closers.contains(next) || next == "," || next == ";" || next == ":") { return false }
        super.insertText("\(ch)\(close)", replacementRange: NSRange(location: NSNotFound, length: 0))
        setSelectedRange(NSRange(location: sel.location + 1, length: 0))
        controller?.typed(String(ch))
        return true
    }

    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length == 0, sel.location > 0 {
            let loc = sel.location
            // Delete an empty pair together.
            if loc < ns.length, let open = Character(UnicodeScalar(ns.character(at: loc - 1)) ?? " ") as Character?,
               let close = Self.pairs[open], Character(UnicodeScalar(ns.character(at: loc)) ?? " ") == close {
                insertText("", replacementRange: NSRange(location: loc - 1, length: 2))
                return
            }
            // Smart backspace through indentation.
            let line = ns.lineRange(for: NSRange(location: loc, length: 0))
            let before = ns.substring(with: NSRange(location: line.location, length: loc - line.location))
            if !before.isEmpty, before.allSatisfy({ $0 == " " }), insertSpaces {
                let unit = max(1, tabWidth)
                let remove = before.count % unit == 0 ? unit : before.count % unit
                insertText("", replacementRange: NSRange(location: loc - remove, length: remove))
                return
            }
        }
        super.deleteBackward(sender)
        controller?.typed("")
    }

    override func insertNewline(_ sender: Any?) {
        if continueMarkdownList() { return }
        let sel = selectedRange()
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let lineText = ns.substring(with: NSRange(location: line.location, length: sel.location - line.location))
        let indent = String(lineText.prefix { $0 == " " || $0 == "\t" })
        let trimmed = lineText.trimmingCharacters(in: .whitespaces)
        var extra = ""
        if let last = trimmed.last {
            if "{[(".contains(last) { extra = indentUnit }
            if last == ":" && ["python", "yaml", "nix"].contains(lang.id) { extra = indentUnit }
            if lang.lexer == .yaml && trimmed.hasSuffix(":") { extra = indentUnit }
            if lang.lexer == .markup, trimmed.hasSuffix(">"), !trimmed.hasPrefix("</"), !trimmed.hasSuffix("/>"),
               let open = trimmed.range(of: "<", options: .backwards), !trimmed[open.lowerBound...].hasPrefix("</") { extra = indentUnit }
        }
        if ["ruby", "lua", "elixir"].contains(lang.id), let first = trimmed.split(separator: " ").first,
           ["def", "class", "module", "if", "unless", "while", "for", "do", "function", "case", "begin"].contains(String(first)) || trimmed.hasSuffix(" do") {
            extra = indentUnit
        }
        let next = NSMaxRange(sel) < ns.length ? ns.character(at: NSMaxRange(sel)) : 0
        let closesPair = next == 125 || next == 93 || next == 41 || (lang.lexer == .markup && next == 60 && NSMaxRange(sel) + 1 < ns.length && ns.character(at: NSMaxRange(sel) + 1) == 47)
        if !extra.isEmpty && closesPair {
            let text = "\n" + indent + extra + "\n" + indent
            insertText(text, replacementRange: sel)
            setSelectedRange(NSRange(location: sel.location + 1 + (indent + extra as NSString).length, length: 0))
        } else {
            insertText("\n" + indent + extra, replacementRange: sel)
        }
        scrollRangeToVisible(selectedRange())
    }

    override func insertTab(_ sender: Any?) {
        if let c = controller, c.completion.isVisible { c.completion.accept(); return }
        if ghost.accept() { return }
        if nextSnippetStop() { return }
        if expandTemplateBeforeCaret() { return }
        let sel = selectedRange()
        if sel.length > 0 && ns.substring(with: sel).contains("\n") { shiftLines(by: 1); return }
        insertText(indentUnit, replacementRange: sel)
    }

    override func insertBacktab(_ sender: Any?) { shiftLines(by: -1) }

    // MARK: Line helpers

    private var selectedLinesRange: NSRange {
        let sel = selectedRange()
        var r = ns.lineRange(for: sel)
        // A selection ending at a line start doesn't include that line.
        if sel.length > 0, NSMaxRange(sel) == r.location + r.length, NSMaxRange(sel) > 0, ns.character(at: NSMaxRange(sel) - 1) == 10,
           NSMaxRange(sel) < NSMaxRange(r) || sel.location < NSMaxRange(sel) - 1 {
            r = ns.lineRange(for: NSRange(location: sel.location, length: max(0, sel.length - 1)))
        }
        return r
    }

    /// Replaces a range through the undo-aware path and selects `select` afterwards.
    func replace(_ range: NSRange, with text: String, select: NSRange? = nil) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        if let select { setSelectedRange(select) }
    }

    private func shiftLines(by delta: Int) {
        let r = selectedLinesRange
        let text = ns.substring(with: r)
        var lines = text.components(separatedBy: "\n")
        let trailing = lines.last == "" ? lines.removeLast() : nil
        let unit = indentUnit
        lines = lines.map { l in
            if delta > 0 { return l.isEmpty ? l : unit + l }
            if l.hasPrefix("\t") { return String(l.dropFirst()) }
            let spaces = l.prefix { $0 == " " }.count
            return String(l.dropFirst(min(spaces, max(1, tabWidth))))
        }
        var out = lines.joined(separator: "\n")
        if trailing != nil { out += "\n" }
        replace(r, with: out, select: NSRange(location: r.location, length: (out as NSString).length - (trailing != nil ? 1 : 0)))
    }

    @objc func toggleComment(_ sender: Any?) {
        let r = selectedLinesRange
        let text = ns.substring(with: r)
        var lines = text.components(separatedBy: "\n")
        let trailing = lines.last == "" ? lines.removeLast() : nil
        if let lc = lang.lineComment ?? (lang.lexer == .markup ? nil : lang.lineComment) {
            let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let allCommented = !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix(lc) }
            let minIndent = nonEmpty.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
            lines = lines.map { l in
                if l.trimmingCharacters(in: .whitespaces).isEmpty { return l }
                if allCommented {
                    guard let range = l.range(of: lc) else { return l }
                    var after = l[range.upperBound...]
                    if after.hasPrefix(" ") { after = after.dropFirst() }
                    return String(l[..<range.lowerBound]) + after
                }
                let idx = l.index(l.startIndex, offsetBy: minIndent)
                return String(l[..<idx]) + lc + " " + l[idx...]
            }
        } else {
            let (open, close) = lang.blockComment ?? (lang.lexer == .markup || lang.lexer == .markdown ? ("<!--", "-->") : ("/*", "*/"))
            let joined = lines.joined(separator: "\n")
            let t = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix(open) && t.hasSuffix(close) {
                lines = [joined.replacingOccurrences(of: open + " ", with: "", options: [], range: joined.range(of: open + " ") ?? joined.range(of: open))
                    .replacingOccurrences(of: " " + close, with: "").replacingOccurrences(of: open, with: "").replacingOccurrences(of: close, with: "")]
            } else {
                let indent = String(joined.prefix { $0 == " " || $0 == "\t" })
                lines = [indent + open + " " + joined.dropFirst(indent.count) + " " + close]
            }
        }
        var out = lines.joined(separator: "\n")
        if trailing != nil { out += "\n" }
        let wasSingle = selectedRange().length == 0
        replace(r, with: out, select: wasSingle ? nil : NSRange(location: r.location, length: (out as NSString).length))
        if wasSingle { moveDown(nil) }
    }

    @objc func duplicateLine(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length > 0 {
            let t = ns.substring(with: sel)
            replace(NSRange(location: NSMaxRange(sel), length: 0), with: t, select: NSRange(location: NSMaxRange(sel), length: sel.length))
            return
        }
        let r = ns.lineRange(for: sel)
        var t = ns.substring(with: r)
        if !t.hasSuffix("\n") { t = "\n" + t
            replace(NSRange(location: NSMaxRange(r), length: 0), with: t, select: NSRange(location: sel.location + (t as NSString).length, length: 0))
        } else {
            replace(NSRange(location: NSMaxRange(r), length: 0), with: t, select: NSRange(location: sel.location + r.length, length: 0))
        }
    }

    @objc func deleteLine(_ sender: Any?) {
        let r = selectedLinesRange
        var del = r
        if NSMaxRange(r) == ns.length, r.location > 0, !ns.substring(with: r).hasSuffix("\n") { del = NSRange(location: r.location - 1, length: r.length + 1) }
        replace(del, with: "", select: NSRange(location: min(del.location, ns.length - del.length), length: 0))
    }

    @objc func moveLineUp(_ sender: Any?) { moveLines(up: true) }
    @objc func moveLineDown(_ sender: Any?) { moveLines(up: false) }

    private func moveLines(up: Bool) {
        let r = selectedLinesRange
        let sel = selectedRange()
        var block = ns.substring(with: r)
        if up {
            guard r.location > 0 else { return }
            let prev = ns.lineRange(for: NSRange(location: r.location - 1, length: 0))
            var prevText = ns.substring(with: prev)
            if !block.hasSuffix("\n") { block += "\n"; prevText = String(prevText.dropLast()) }
            replace(NSRange(location: prev.location, length: prev.length + r.length), with: block + prevText,
                    select: NSRange(location: sel.location - prev.length, length: sel.length))
        } else {
            guard NSMaxRange(r) < ns.length else { return }
            let next = ns.lineRange(for: NSRange(location: NSMaxRange(r), length: 0))
            var nextText = ns.substring(with: next)
            if !nextText.hasSuffix("\n") { nextText += "\n"; block = String(block.dropLast()) }
            replace(NSRange(location: r.location, length: r.length + next.length), with: nextText + block,
                    select: NSRange(location: sel.location + (nextText as NSString).length, length: sel.length))
        }
    }

    /// ⌥↑ — extend selection to the word, then the line, then everything (JetBrains "Extend Selection").
    @objc func extendSelection(_ sender: Any?) {
        let sel = selectedRange()
        let word = selectionRange(forProposedRange: NSRange(location: sel.location, length: 0), granularity: .selectByWord)
        if sel.length < word.length || !NSEqualRanges(NSUnionRange(sel, word), word) && sel.length == 0 { setSelectedRange(word); return }
        // Enclosing brackets
        if let enclosing = enclosingBrackets(sel), enclosing.length > sel.length { setSelectedRange(enclosing); return }
        let line = ns.lineRange(for: sel)
        if line.length > sel.length { setSelectedRange(line); return }
        selectAll(nil)
    }

    private func enclosingBrackets(_ sel: NSRange) -> NSRange? {
        let opens: [unichar: unichar] = [40: 41, 91: 93, 123: 125]
        var depth: [unichar: Int] = [:]
        var i = sel.location - 1
        while i >= 0 && sel.location - i < 20000 {
            let c = ns.character(at: i)
            if [41, 93, 125].contains(c) { depth[c, default: 0] += 1 }
            if let close = opens[c] {
                if depth[close, default: 0] == 0 {
                    // find matching close
                    var d = 0, j = i + 1
                    while j < ns.length {
                        let k = ns.character(at: j)
                        if k == c { d += 1 } else if k == close { if d == 0 { break }; d -= 1 }
                        j += 1
                    }
                    guard j < ns.length else { return nil }
                    let inner = NSRange(location: i + 1, length: j - i - 1)
                    return inner.length > sel.length ? inner : NSRange(location: i, length: j - i + 1)
                }
                depth[close]! -= 1
            }
            i -= 1
        }
        return nil
    }

    // MARK: Mouse

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.controller?.fixHorizontalOrigin() } }
    }

    override func mouseDown(with event: NSEvent) {
        ghost.hide()
        hideHover()
        controller?.completion.hide()
        if toggleMarkdownCheckbox(event) { return }
        // ⌥-click adds a caret; ⌥-drag makes a column selection (adopted as carets).
        if event.modifierFlags.contains(.option) && !event.modifierFlags.contains(.command) {
            let before = allCursors
            super.mouseDown(with: event)
            if selectedRanges.count > 1 { adoptNativeMultiSelection(); return }
            let clicked = selectedRange()
            if let existing = before.firstIndex(where: { NSLocationInRange(clicked.location, $0) || $0.location == clicked.location }), before.count > 1 {
                var rest = before; rest.remove(at: existing); setCursors(rest)   // ⌥-click an existing caret removes it
            } else {
                setCursors(before + [clicked])
            }
            return
        }
        clearExtraCursors()
        if let c = controller, let f = c.foldPlaceholder(at: convert(event.locationInWindow, from: nil)) { c.unfold(f); return }
        if event.modifierFlags.contains(.command) {
            let p = convert(event.locationInWindow, from: nil)
            let idx = characterIndexForInsertion(at: p)
            if handleCommandClick(at: idx) { return }
            setSelectedRange(NSRange(location: idx, length: 0))
            controller?.goToDefinition()
            return
        }
        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: visibleRect, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let p = convert(event.locationInWindow, from: nil)
        if controller?.info.isVisible == true, hypot(p.x - hoverPoint.x, p.y - hoverPoint.y) > 12 { controller?.info.hideIfHover() }
        hoverTimer?.invalidate()
        guard prefs.hoverDocs else { return }
        hoverPoint = p
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let lm = self.layoutManager, let tc = self.textContainer else { return }
                let local = NSPoint(x: p.x - self.textContainerOrigin.x, y: p.y - self.textContainerOrigin.y)
                var frac: CGFloat = 0
                let g = lm.glyphIndex(for: local, in: tc, fractionOfDistanceThroughGlyph: &frac)
                guard lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc).insetBy(dx: -2, dy: -2).contains(local) else { return }
                let idx = lm.characterIndexForGlyph(at: g)
                self.controller?.hover(at: idx, mouse: true)
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverTimer?.invalidate()
        controller?.info.hideIfHover()
    }

    private func hideHover() {
        hoverTimer?.invalidate()
        controller?.info.hideIfHover()
    }

    override func scrollWheel(with event: NSEvent) {
        hideHover()
        controller?.completion.hide()
        super.scrollWheel(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let idx = characterIndexForInsertion(at: p)
        if selectedRange().length == 0 { setSelectedRange(NSRange(location: idx, length: 0)) }
        let menu = NSMenu()
        func item(_ t: String, _ sel: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = []) {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            menu.addItem(i)
        }
        item("Show Context Actions", #selector(showContextActions(_:)), "\r", [.option])
        item("Go to Definition", #selector(goToDefinitionAction(_:)), "b", [.command])
        item("Find Usages", #selector(findUsages(_:)))
        item("Rename…", #selector(renameSymbol(_:)))
        item("Quick Documentation", #selector(quickDocumentation(_:)))
        item("Reformat Code", #selector(reformatCode(_:)), "l", [.command, .option])
        menu.addItem(.separator())
        item("Cut", #selector(cut(_:)), "x", [.command])
        item("Copy", #selector(copy(_:)), "c", [.command])
        item("Paste", #selector(paste(_:)), "v", [.command])
        menu.addItem(.separator())
        item("Toggle Comment", #selector(toggleComment(_:)), "/", [.command])
        menu.addItem(.separator())
        item(selectedRange().length > 0 ? "Explain Selection with AI" : "Explain This Code with AI", #selector(aiExplain(_:)))
        if diagnosticAtCaret != nil { item("Fix This Problem with AI", #selector(aiFix(_:))) }
        return menu
    }

    // MARK: Code actions (menu items reach these through the responder chain)

    @objc func showContextActions(_ sender: Any?) { controller?.showContextActions() }
    var diagnosticAtCaret: Diagnostic? {
        let loc = selectedRange().location
        return controller?.document?.diagnostics.first { NSLocationInRange(loc, NSRange(location: $0.range.location, length: max(1, $0.range.length))) }
            ?? controller?.document.flatMap { d in d.diagnostics.first { $0.line + 1 == d.cursorLine } }
    }
    @objc func aiExplain(_ sender: Any?) { controller?.workspace?.assistant.explainSelection() }
    @objc func aiFix(_ sender: Any?) {
        guard let d = diagnosticAtCaret, let doc = controller?.document else { NSSound.beep(); return }
        controller?.workspace?.assistant.fix(d, in: doc.url)
    }
    @objc func goToDefinitionAction(_ sender: Any?) { controller?.goToDefinition() }
    @objc func findUsages(_ sender: Any?) { controller?.findUsages() }
    @objc func renameSymbol(_ sender: Any?) { controller?.renameSymbol() }
    @objc func quickDocumentation(_ sender: Any?) { controller?.hover(at: selectedRange().location, mouse: false) }
    @objc func reformatCode(_ sender: Any?) { controller?.reformat() }
    @objc func triggerCompletion(_ sender: Any?) { controller?.completion.trigger(manual: true) }
    @objc func fileStructure(_ sender: Any?) { controller?.showFileStructure() }
    @objc func nextError(_ sender: Any?) { controller?.jumpToDiagnostic(forward: true) }
    @objc func previousError(_ sender: Any?) { controller?.jumpToDiagnostic(forward: false) }
    @objc func goToLine(_ sender: Any?) { controller?.promptGoToLine() }

    // Plain-text paste only (no rich text), keep indentation sane.
    override func paste(_ sender: Any?) {
        if hasMultipleCursors { multiPaste(); return }
        pasteAsPlainText(sender)
    }

    @objc func foldCode(_ sender: Any?) { controller?.foldAtCaret() }
    @objc func unfoldCode(_ sender: Any?) { controller?.unfoldAtCaret() }
    @objc func foldAllCode(_ sender: Any?) { controller?.foldAll() }
    @objc func unfoldAllCode(_ sender: Any?) { controller?.unfoldAll() }

    @objc func toggleBreakpointAtCaret(_ sender: Any?) {
        guard let doc = controller?.document, let ws = controller?.workspace else { return }
        ws.debug.toggleBreakpoint(doc.url, line: doc.lineIndex.line(of: selectedRange().location) + 1)
    }

    @objc func toggleBookmark(_ sender: Any?) {
        guard let doc = controller?.document, let ws = controller?.workspace else { return }
        ws.bookmarks.toggle(doc.url, line: doc.lineIndex.line(of: selectedRange().location) + 1)
        controller?.ruler?.needsDisplay = true
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
}


extension CodeTextView {
    /// Clicking the [ ] of a Markdown task ("- [ ] milk") ticks it, and back (undoable).
    func toggleMarkdownCheckbox(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.option, .command, .shift]).isEmpty, event.clickCount == 1,
              controller?.document?.language.lexer == .markdown, Prefs.shared.markdownStyling else { return false }
        let p = convert(event.locationInWindow, from: nil)
        let i = characterIndexForInsertion(at: p)
        let ns = string as NSString
        guard i <= ns.length else { return false }
        let line = ns.lineRange(for: NSRange(location: min(i, max(0, ns.length - 1)), length: 0))
        let text = ns.substring(with: line)
        guard let m = text.firstMatch(of: #/^(\s*[-*+] )\[([ xX])\]/#) else { return false }
        let box = NSRange(location: line.location + m.1.count, length: 3)
        guard i >= box.location - 1 && i <= NSMaxRange(box) + 1 else { return false }
        let on = m.2 != " "
        let r = NSRange(location: box.location + 1, length: 1)
        if shouldChangeText(in: r, replacementString: on ? " " : "x") {
            textStorage?.replaceCharacters(in: r, with: on ? " " : "x")
            didChangeText()
        }
        return true
    }
}
