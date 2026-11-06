import AppKit

/// Code folding. Folded text stays in the document; its glyphs are hidden by the layout manager and the
/// first hidden character is drawn as a "⋯" placeholder you can click to unfold.
extension EditorController {
    static let placeholderWidth: CGFloat = 26
    private static let indentFoldLanguages: Set<String> = ["python", "yaml", "html", "xml", "vue", "svelte", "ruby", "lua", "elixir", "haskell", "nix", "markdown", "graphql", "toml", "properties"]

    // MARK: Regions

    func computeFoldRegions() {
        guard let doc = document, doc.storage.length < 1_500_000 else { foldRegions = [:]; return }
        let ns = doc.storage.string as NSString
        let idx = doc.lineIndex
        var regions: [Int: NSRange] = [:]
        if Self.indentFoldLanguages.contains(doc.language.id) {
            regions = indentRegions(ns, idx)
        } else if doc.language.lexer != .plain {
            regions = bracketRegions(ns, idx)
        }
        foldRegions = regions
        ruler?.needsDisplay = true
    }

    private func bracketRegions(_ ns: NSString, _ idx: LineIndex) -> [Int: NSRange] {
        let len = ns.length
        var buf = [unichar](repeating: 0, count: len)
        ns.getCharacters(&buf, range: NSRange(location: 0, length: len))
        // Mark string / comment spans so brackets inside them are ignored.
        var skip = [Bool](repeating: false, count: len)
        for t in tokensSnapshot where t.kind == .string || t.kind == .comment || t.kind == .regex {
            let a = Int(t.start), b = min(len, a + Int(t.length))
            if a < b { for i in a..<b { skip[i] = true } }
        }
        var stack: [(unichar, Int)] = []
        var regions: [Int: NSRange] = [:]
        for i in 0..<len where !skip[i] {
            let c = buf[i]
            if c == 123 || c == 91 || c == 40 { stack.append((c, i)); continue }
            guard c == 125 || c == 93 || c == 41, let (open, o) = stack.last else { continue }
            let expected: unichar = c == 125 ? 123 : c == 93 ? 91 : 40
            guard open == expected else { continue }
            stack.removeLast()
            let startLine = idx.line(of: o), endLine = idx.line(of: i)
            guard endLine > startLine else { continue }
            let hidden = NSRange(location: o + 1, length: i - o - 1)
            // Keep the widest region per line (e.g. `foo({` folds the brace block).
            if let existing = regions[startLine], existing.length >= hidden.length { continue }
            regions[startLine] = hidden
        }
        return regions
    }

    private func indentRegions(_ ns: NSString, _ idx: LineIndex) -> [Int: NSRange] {
        var indents: [Int?] = []
        var contentEnds: [Int] = []
        for line in 0..<idx.lineCount {
            let start = idx.starts[line]
            let end = line + 1 < idx.lineCount ? idx.starts[line + 1] - 1 : ns.length
            var i = start, width = 0
            while i < end, ns.character(at: i) == 32 || ns.character(at: i) == 9 { width += ns.character(at: i) == 9 ? 4 : 1; i += 1 }
            indents.append(i == end ? nil : width)
            contentEnds.append(end)
        }
        var regions: [Int: NSRange] = [:]
        for line in 0..<indents.count {
            guard let ind = indents[line] else { continue }
            var last = line
            var j = line + 1
            while j < indents.count {
                if let x = indents[j] { if x <= ind { break }; last = j }
                j += 1
            }
            guard last > line else { continue }
            let from = contentEnds[line], to = contentEnds[last]
            if to > from { regions[line] = NSRange(location: from, length: to - from) }
        }
        return regions
    }

    // MARK: Folding

    func isFolded(line: Int) -> Bool {
        guard let r = foldRegions[line] else { return false }
        return folds.contains { $0.location == r.location }
    }

    func toggleFold(line: Int) {
        guard let r = foldRegions[line] else { return }
        if let i = folds.firstIndex(where: { $0.location == r.location }) {
            let f = folds.remove(at: i)
            invalidate(f)
        } else {
            fold(r)
        }
    }

    private func fold(_ r: NSRange) {
        guard r.length > 0 else { return }
        // Nested folds inside a new fold are absorbed by it.
        folds.removeAll { NSLocationInRange($0.location, r) && NSMaxRange($0) <= NSMaxRange(r) }
        folds.append(r)
        folds.sort { $0.location < $1.location }
        let sel = textView.selectedRange()
        if NSLocationInRange(sel.location, r) { textView.setSelectedRange(NSRange(location: r.location, length: 0)) }
        invalidate(r)
    }

    func foldAtCaret() {
        guard let doc = document else { return }
        let caret = textView.selectedRange().location
        // Innermost region containing the caret, else the region starting on this line.
        let line = doc.lineIndex.line(of: caret)
        if let r = foldRegions.values.filter({ NSLocationInRange(caret, $0) && !folds.contains($0) }).min(by: { $0.length < $1.length }) {
            fold(r)
        } else if let r = foldRegions[line] { fold(r) }
    }

    func unfoldAtCaret() {
        guard let doc = document else { return }
        let caret = textView.selectedRange().location
        let line = doc.lineIndex.line(of: caret)
        let lineEnd = line + 1 < doc.lineIndex.lineCount ? doc.lineIndex.starts[line + 1] : doc.storage.length
        if let i = folds.firstIndex(where: { $0.location >= doc.lineIndex.starts[line] && $0.location <= lineEnd || NSLocationInRange(caret, $0) }) {
            invalidate(folds.remove(at: i))
        }
    }

    func foldAll() {
        // Fold top-level regions only (regions not inside another region).
        let all = foldRegions.values.sorted { $0.location < $1.location }
        var top: [NSRange] = []
        for r in all where !top.contains(where: { NSLocationInRange(r.location, $0) }) { top.append(r) }
        // With a single top-level block (e.g. one class), fold its direct children instead so the outline stays visible.
        var targets = top
        if top.count == 1 {
            let outer = top[0]
            let inner = all.filter { $0 != outer && NSLocationInRange($0.location, outer) }
            targets = inner.filter { r in !inner.contains { o in o != r && NSLocationInRange(r.location, o) } }
            if targets.isEmpty { targets = top }
        }
        folds = targets
        invalidateAll()
    }

    func unfoldAll() {
        folds = []
        invalidateAll()
    }

    func unfoldIfCaretInside() {
        guard !folds.isEmpty else { return }
        let sel = textView.selectedRange()
        if let i = folds.firstIndex(where: { NSLocationInRange(sel.location, $0) && sel.location != $0.location }) {
            invalidate(folds.remove(at: i))
        }
    }

    /// Keeps folds aligned with the text when it's edited; editing inside a fold unfolds it.
    func textWillChange(_ range: NSRange, replacementLength: Int) {
        guard !folds.isEmpty else { return }
        let delta = replacementLength - range.length
        var dropped: [NSRange] = []
        folds = folds.compactMap { f in
            if NSMaxRange(range) <= f.location { return NSRange(location: f.location + delta, length: f.length) }
            if range.location >= NSMaxRange(f) { return f }
            dropped.append(f)
            return nil
        }
        if !dropped.isEmpty { DispatchQueue.main.async { self.invalidateAll() } }
    }

    private func invalidate(_ r: NSRange) {
        let len = layoutManager.textStorage?.length ?? 0
        let ext = NSRange(location: max(0, r.location - 1), length: min(len - max(0, r.location - 1), r.length + 2))
        layoutManager.invalidateGlyphs(forCharacterRange: ext, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: ext, actualCharacterRange: nil)
        textView.needsDisplay = true
        ruler?.needsDisplay = true
    }

    private func invalidateAll() {
        let len = layoutManager.textStorage?.length ?? 0
        invalidate(NSRange(location: 0, length: len))
    }

    func fold(containing index: Int) -> NSRange? {
        var lo = 0, hi = folds.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let f = folds[mid]
            if index < f.location { hi = mid - 1 } else if index >= NSMaxRange(f) { lo = mid + 1 } else { return f }
        }
        return nil
    }

    // MARK: NSLayoutManagerDelegate

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>, properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard !folds.isEmpty else { return 0 }
        var changed = false
        var newProps = [NSLayoutManager.GlyphProperty](UnsafeBufferPointer(start: props, count: glyphRange.length))
        for i in 0..<glyphRange.length {
            let c = charIndexes[i]
            guard let f = fold(containing: c) else { continue }
            newProps[i] = c == f.location ? .controlCharacter : .null
            changed = true
        }
        guard changed else { return 0 }
        newProps.withUnsafeBufferPointer { layoutManager.setGlyphs(glyphs, properties: $0.baseAddress!, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange) }
        return glyphRange.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction, forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        guard let f = fold(containing: charIndex) else { return action }
        return charIndex == f.location ? .whitespace : .zeroAdvancement
    }

    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int, for textContainer: NSTextContainer,
                       proposedLineFragment proposedRect: NSRect, glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        NSRect(x: glyphPosition.x, y: 0, width: Self.placeholderWidth, height: proposedRect.height)
    }

    /// Draws the "⋯" pills for folded regions.
    func drawFoldPlaceholders(in rect: NSRect) {
        guard !folds.isEmpty else { return }
        let lm = layoutManager
        for f in folds {
            let g = lm.glyphIndexForCharacter(at: f.location)
            guard g < lm.numberOfGlyphs else { continue }
            let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let x = lm.location(forGlyphAt: g).x + frag.minX + textView.textContainerOrigin.x
            let pill = NSRect(x: x + 2, y: frag.minY + textView.textContainerOrigin.y + frag.height * 0.18, width: Self.placeholderWidth - 4, height: frag.height * 0.64)
            guard pill.intersects(rect) else { continue }
            (Theme.isDark ? Palette.hex("393B40") : Palette.hex("E8EAF0")).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: max(9, Prefs.shared.editorFont.pointSize - 2), weight: .bold), .foregroundColor: NSColor.secondaryLabelColor]
            let s = "⋯" as NSString
            let size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2), withAttributes: attrs)
        }
    }

    /// The fold whose placeholder is at a point (for click-to-unfold).
    func foldPlaceholder(at point: NSPoint) -> NSRange? {
        let lm = layoutManager
        for f in folds {
            let g = lm.glyphIndexForCharacter(at: f.location)
            guard g < lm.numberOfGlyphs else { continue }
            let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let x = lm.location(forGlyphAt: g).x + frag.minX + textView.textContainerOrigin.x
            let r = NSRect(x: x, y: frag.minY + textView.textContainerOrigin.y, width: Self.placeholderWidth, height: frag.height)
            if r.contains(point) { return f }
        }
        return nil
    }

    func unfold(_ f: NSRange) {
        if let i = folds.firstIndex(of: f) { invalidate(folds.remove(at: i)) }
    }

    /// Copying a selection that spans a fold copies the real text (it's still in the document).
    var hasFolds: Bool { !folds.isEmpty }
}
