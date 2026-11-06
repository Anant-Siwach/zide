import AppKit

/// Multiple carets / selections. The primary caret is NSTextView's own selection; extra carets are
/// stored in `extraCursors` and drawn by us. Edits and moves are applied to all of them at once.
extension CodeTextView {
    var allCursors: [NSRange] { ([selectedRange()] + extraCursors).sorted { $0.location < $1.location } }
    var hasMultipleCursors: Bool { !extraCursors.isEmpty }

    /// Sets every caret; the last one becomes the primary (so scrolling follows it).
    func setCursors(_ ranges: [NSRange], primaryLast: Bool = true) {
        let len = (string as NSString).length
        var sorted = ranges.map { NSRange(location: min(max(0, $0.location), len), length: max(0, min($0.length, len - min(max(0, $0.location), len)))) }
            .sorted { $0.location < $1.location }
        // Merge overlapping / duplicate carets.
        var merged: [NSRange] = []
        for r in sorted {
            if let last = merged.last, r.location <= NSMaxRange(last), !(r.length == 0 && last.length == 0 && r.location != last.location) {
                merged[merged.count - 1] = NSUnionRange(last, r)
            } else { merged.append(r) }
        }
        sorted = merged
        guard !sorted.isEmpty else { return }
        let primary = primaryLast ? sorted.removeLast() : sorted.removeFirst()
        extraCursors = sorted
        isSettingCursors = true
        setSelectedRange(primary)
        isSettingCursors = false
        scrollRangeToVisible(primary)
        needsDisplay = true
    }

    func clearExtraCursors() {
        guard hasMultipleCursors else { return }
        extraCursors = []
        needsDisplay = true
    }

    /// Native ⌥-drag column selection produces several selected ranges; adopt them as carets.
    func adoptNativeMultiSelection() {
        let ranges = selectedRanges.map(\.rangeValue)
        guard ranges.count > 1 else { return }
        setCursors(ranges, primaryLast: false)
    }

    // MARK: Editing all carets

    /// Applies one edit per caret (back to front, one undo step) and places carets after each edit.
    func editAll(_ make: (NSRange) -> (range: NSRange, text: String, caretOffset: Int?)?) {
        let ns = string as NSString
        var edits: [(range: NSRange, text: String, caretOffset: Int?)] = []
        for c in allCursors {
            guard let e = make(c), NSMaxRange(e.range) <= ns.length else { continue }
            if let last = edits.last, e.range.location < NSMaxRange(last.range) { continue }
            edits.append(e)
        }
        guard !edits.isEmpty else { return }
        inMultiEdit = true
        undoManager?.beginUndoGrouping()
        for e in edits.reversed() where shouldChangeText(in: e.range, replacementString: e.text) {
            textStorage?.replaceCharacters(in: e.range, with: e.text)
            didChangeText()
        }
        undoManager?.endUndoGrouping()
        inMultiEdit = false
        var delta = 0
        var carets: [NSRange] = []
        for e in edits {
            let start = e.range.location + delta
            let len = (e.text as NSString).length
            carets.append(NSRange(location: start + (e.caretOffset ?? len), length: 0))
            delta += len - e.range.length
        }
        setCursors(carets)
    }

    func multiInsert(_ s: String) {
        editAll { r in (r, s, nil) }
    }

    // MARK: Commands

    /// Handles a text command for all carets. Returns false to let NSTextView handle it (after clearing extras).
    func handleMultiCommand(_ sel: Selector) -> Bool {
        let ns = string as NSString
        let len = ns.length
        func lineStart(_ i: Int) -> Int { ns.lineRange(for: NSRange(location: min(i, len), length: 0)).location }
        func lineEnd(_ i: Int) -> Int {
            let r = ns.lineRange(for: NSRange(location: min(i, len), length: 0))
            var e = NSMaxRange(r)
            if e > r.location && e <= len && e > 0 && ns.character(at: e - 1) == 10 { e -= 1 }
            return e
        }
        func wordLeft(_ i: Int) -> Int {
            var j = i
            while j > 0 && !EditorController.isIdent(ns.character(at: j - 1)) { j -= 1 }
            while j > 0 && EditorController.isIdent(ns.character(at: j - 1)) { j -= 1 }
            return j
        }
        func wordRight(_ i: Int) -> Int {
            var j = i
            while j < len && !EditorController.isIdent(ns.character(at: j)) { j += 1 }
            while j < len && EditorController.isIdent(ns.character(at: j)) { j += 1 }
            return j
        }
        func vertical(_ i: Int, _ dir: Int) -> Int {
            let ls = lineStart(i)
            let col = i - ls
            if dir < 0 {
                guard ls > 0 else { return 0 }
                let prev = lineStart(ls - 1)
                return min(prev + col, lineEnd(prev))
            } else {
                let le = lineEnd(i)
                guard le < len else { return len }
                let next = le + 1
                return min(next + col, lineEnd(next))
            }
        }
        func move(_ f: (Int) -> Int, collapse: (NSRange) -> Int?) {
            setCursors(allCursors.map { r in NSRange(location: r.length > 0 ? (collapse(r) ?? f(r.location)) : f(r.location), length: 0) })
        }
        /// Extends each selection by moving its active end (end for rightward, start for leftward).
        func extend(_ f: (Int) -> Int, forward: Bool) {
            setCursors(allCursors.map { r in
                if forward { let e = f(NSMaxRange(r)); return NSRange(location: r.location, length: max(0, e - r.location)) }
                let s = f(r.location); return NSRange(location: s, length: NSMaxRange(r) - s)
            })
        }

        switch sel {
        case #selector(moveLeft(_:)): move({ max(0, $0 - 1) }, collapse: { $0.location })
        case #selector(moveRight(_:)): move({ min(len, $0 + 1) }, collapse: { NSMaxRange($0) })
        case #selector(moveUp(_:)): move({ vertical($0, -1) }, collapse: { _ in nil })
        case #selector(moveDown(_:)): move({ vertical($0, 1) }, collapse: { _ in nil })
        case #selector(moveWordLeft(_:)), #selector(moveWordBackward(_:)): move(wordLeft, collapse: { _ in nil })
        case #selector(moveWordRight(_:)), #selector(moveWordForward(_:)): move(wordRight, collapse: { _ in nil })
        case #selector(moveToBeginningOfLine(_:)), #selector(moveToLeftEndOfLine(_:)): move(lineStart, collapse: { _ in nil })
        case #selector(moveToEndOfLine(_:)), #selector(moveToRightEndOfLine(_:)): move(lineEnd, collapse: { _ in nil })
        case #selector(moveLeftAndModifySelection(_:)): extend({ max(0, $0 - 1) }, forward: false)
        case #selector(moveRightAndModifySelection(_:)): extend({ min(len, $0 + 1) }, forward: true)
        case #selector(moveWordLeftAndModifySelection(_:)): extend(wordLeft, forward: false)
        case #selector(moveWordRightAndModifySelection(_:)): extend(wordRight, forward: true)
        case #selector(moveToBeginningOfLineAndModifySelection(_:)), #selector(moveToLeftEndOfLineAndModifySelection(_:)): extend(lineStart, forward: false)
        case #selector(moveToEndOfLineAndModifySelection(_:)), #selector(moveToRightEndOfLineAndModifySelection(_:)): extend(lineEnd, forward: true)
        case #selector(deleteBackward(_:)):
            editAll { r in r.length > 0 ? (r, "", nil) : (r.location > 0 ? (NSRange(location: r.location - 1, length: 1), "", nil) : nil) }
        case #selector(deleteForward(_:)):
            editAll { r in r.length > 0 ? (r, "", nil) : (r.location < len ? (NSRange(location: r.location, length: 1), "", nil) : nil) }
        case #selector(deleteWordBackward(_:)):
            editAll { r in r.length > 0 ? (r, "", nil) : { let s = wordLeft(r.location); return (NSRange(location: s, length: r.location - s), "", nil) }() }
        case #selector(deleteToBeginningOfLine(_:)):
            editAll { r in let s = lineStart(r.location); return (NSRange(location: s, length: NSMaxRange(r) - s), "", nil) }
        case #selector(insertNewline(_:)):
            editAll { r in
                let ls = lineStart(r.location)
                let indent = String(ns.substring(with: NSRange(location: ls, length: r.location - ls)).prefix { $0 == " " || $0 == "\t" })
                return (r, "\n" + indent, nil)
            }
        case #selector(insertTab(_:)): multiInsert(Prefs.shared.indentUnit)
        case #selector(cancelOperation(_:)):
            // Esc keeps only the primary caret.
            clearExtraCursors()
        case #selector(selectAll(_:)):
            return false
        default:
            return false
        }
        return true
    }

    // MARK: Adding carets

    /// ⌃G: select the word, then add the next occurrence of the selection.
    @objc func selectNextOccurrence(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        if sel.length == 0 && !hasMultipleCursors {
            guard let word = controller?.wordRange(at: sel.location), word.length > 0 else { return }
            setSelectedRange(word)
            return
        }
        let target = ns.substring(with: sel)
        guard !target.isEmpty else { return }
        let cursors = allCursors
        let after = NSMaxRange(cursors.last ?? sel)
        var found = ns.range(of: target, options: .literal, range: NSRange(location: after, length: ns.length - after))
        if found.location == NSNotFound { found = ns.range(of: target, options: .literal, range: NSRange(location: 0, length: ns.length)) }
        guard found.location != NSNotFound, !cursors.contains(where: { NSEqualRanges($0, found) }) else {
            controller?.workspace?.flash("No more occurrences of “\(target)”")
            return
        }
        setCursors(cursors + [found])
    }

    /// ⌃⌘G: a caret on every occurrence of the selection (or the word under the caret).
    @objc func selectAllOccurrences(_ sender: Any?) {
        let ns = string as NSString
        var sel = selectedRange()
        if sel.length == 0, let w = controller?.wordRange(at: sel.location), w.length > 0 { sel = w }
        guard sel.length > 0 else { return }
        let target = ns.substring(with: sel)
        var ranges: [NSRange] = []
        var search = NSRange(location: 0, length: ns.length)
        while ranges.count < 2000 {
            let r = ns.range(of: target, options: .literal, range: search)
            if r.location == NSNotFound { break }
            ranges.append(r)
            search = NSRange(location: NSMaxRange(r), length: ns.length - NSMaxRange(r))
        }
        setCursors(ranges)
        controller?.workspace?.flash("\(ranges.count) carets")
    }

    @objc func addCaretAbove(_ sender: Any?) { addCaret(vertical: -1) }
    @objc func addCaretBelow(_ sender: Any?) { addCaret(vertical: 1) }

    private func addCaret(vertical dir: Int) {
        let ns = string as NSString
        let cursors = allCursors
        guard let edge = dir < 0 ? cursors.first : cursors.last else { return }
        let line = ns.lineRange(for: NSRange(location: edge.location, length: 0))
        let col = edge.location - line.location
        let target: NSRange
        if dir < 0 {
            guard line.location > 0 else { return }
            target = ns.lineRange(for: NSRange(location: line.location - 1, length: 0))
        } else {
            guard NSMaxRange(line) < ns.length else { return }
            target = ns.lineRange(for: NSRange(location: NSMaxRange(line), length: 0))
        }
        var end = NSMaxRange(target)
        if end > target.location, end <= ns.length, ns.character(at: end - 1) == 10 { end -= 1 }
        setCursors(cursors + [NSRange(location: min(target.location + col, end), length: 0)])
    }

    // MARK: Clipboard

    func multiCopyText() -> String { allCursors.map { (string as NSString).substring(with: $0) }.joined(separator: "\n") }

    func multiPaste() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let lines = text.components(separatedBy: "\n")
        let count = allCursors.count
        var i = 0
        if lines.count == count {
            editAll { r in defer { i += 1 }; return (r, lines[i], nil) }
        } else {
            multiInsert(text)
        }
    }

    // MARK: Drawing

    func drawExtraSelections(in rect: NSRect) {
        guard hasMultipleCursors, let lm = layoutManager, let tc = textContainer else { return }
        Theme.current.selection.setFill()
        for r in extraCursors where r.length > 0 {
            let g = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            lm.enumerateEnclosingRects(forGlyphRange: g, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: tc) { box, _ in
                box.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y).intersection(rect).fill()
            }
        }
    }

    func drawExtraCarets(in rect: NSRect) {
        guard hasMultipleCursors, let lm = layoutManager, let tc = textContainer else { return }
        (insertionPointColor ?? .textColor).setFill()
        let len = (string as NSString).length
        for r in extraCursors {
            let loc = r.length > 0 ? NSMaxRange(r) : r.location
            var caret: NSRect
            if loc >= len {
                caret = lm.extraLineFragmentRect.isEmpty && len > 0
                    ? lm.boundingRect(forGlyphRange: NSRange(location: lm.glyphIndexForCharacter(at: len - 1), length: 1), in: tc).offsetBy(dx: 0, dy: 0)
                    : lm.extraLineFragmentRect
                if !lm.extraLineFragmentRect.isEmpty { caret.size.width = 0 } else { caret.origin.x = caret.maxX }
            } else {
                let g = lm.glyphIndexForCharacter(at: loc)
                let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
                let x = lm.location(forGlyphAt: g).x + frag.minX
                caret = NSRect(x: x, y: frag.minY, width: 0, height: frag.height)
            }
            let r = NSRect(x: caret.minX + textContainerOrigin.x, y: caret.minY + textContainerOrigin.y, width: 2, height: caret.height)
            if r.intersects(rect) { r.fill() }
        }
    }
}
