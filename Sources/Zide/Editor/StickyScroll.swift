import AppKit

/// Sticky scroll: the headers of the functions/blocks the top of the screen is inside stay pinned above the text.
/// Click one to jump to it. Built from the fold regions, so it costs nothing extra to compute.
final class StickyHeaderView: NSView {
    weak var controller: EditorController?
    private var lines: [(line: Int, text: NSAttributedString)] = []
    private var lineHeight: CGFloat = 18
    private var gutter: CGFloat = 0, textX: CGFloat = 4
    override var isFlipped: Bool { true }

    func update(_ entries: [(Int, NSAttributedString)], lineHeight: CGFloat, gutter: CGFloat = 0, textX: CGFloat = 4) {
        self.lineHeight = lineHeight
        if gutter != self.gutter || textX != self.textX { self.gutter = gutter; self.textX = textX; needsDisplay = true }
        let changed = entries.map(\.0) != lines.map(\.line)
        lines = entries.map { ($0.0, $0.1) }
        isHidden = lines.isEmpty
        frame.size.height = CGFloat(lines.count) * lineHeight + (lines.isEmpty ? 0 : 3)
        if changed { needsDisplay = true }
    }

    override func draw(_ dirty: NSRect) {
        let p = Theme.current
        p.background.setFill(); bounds.fill()
        if gutter > 0 { p.gutter.setFill(); NSRect(x: 0, y: 0, width: gutter, height: bounds.height).fill() }
        let numFont = NSFont.monospacedDigitSystemFont(ofSize: max(9, (lines.first?.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 12) - 1, weight: .regular)
        for (i, l) in lines.enumerated() {
            let y = CGFloat(i) * lineHeight
            if gutter > 0 {
                let num = NSAttributedString(string: "\(l.line + 1)", attributes: [.font: numFont, .foregroundColor: p.gutterText])
                num.draw(at: NSPoint(x: gutter - 22 - num.size().width, y: y + (lineHeight - num.size().height) / 2))
            }
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: gutter, y: 0, width: bounds.width - gutter, height: bounds.height).clip()
            l.text.draw(at: NSPoint(x: textX, y: y + (lineHeight - l.text.size().height) / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
        // A soft shadow line separates the pinned headers from the text below.
        p.indentGuide.setFill()
        NSRect(x: 0, y: bounds.height - 1.5, width: bounds.width, height: 1.5).fill()
    }

    override func mouseDown(with e: NSEvent) {
        let y = convert(e.locationInWindow, from: nil).y
        let i = Int(y / lineHeight)
        guard lines.indices.contains(i), let c = controller, let doc = c.document else { return }
        let start = doc.lineIndex.starts[lines[i].line]
        c.textView.setSelectedRange(NSRange(location: start, length: 0))
        c.textView.scrollRangeToVisible(NSRange(location: start, length: 0))
        c.textView.window?.makeFirstResponder(c.textView)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

extension EditorController {
    /// Recomputes the pinned headers for the current scroll position.
    func updateStickyHeaders() {
        guard let sticky = stickyView, let doc = document else { return }
        guard Prefs.shared.stickyScroll, !foldRegions.isEmpty, !doc.isTooLarge else { sticky.update([], lineHeight: 18); return }
        let tv = textView
        let lm = layoutManager
        let visible = scrollView.contentView.bounds
        let lineHeight = lm.defaultLineHeight(for: tv.font ?? Prefs.shared.editorFont) * CGFloat(Prefs.shared.lineHeight)
        guard visible.minY + scrollView.contentView.contentInsets.top > 2 else { sticky.update([], lineHeight: lineHeight); return }
        let ns = doc.storage.string as NSString
        let idx = doc.lineIndex
        func lineAt(_ y: CGFloat) -> Int {
            let point = NSPoint(x: 0, y: y - tv.textContainerOrigin.y)
            let glyph = lm.glyphIndex(for: point, in: tv.textContainer!)
            return idx.line(of: lm.characterIndexForGlyph(at: glyph))
        }
        func scopes(at line: Int) -> [Int] {
            foldRegions.compactMap { start, hidden -> Int? in
                guard start < line, idx.line(of: NSMaxRange(hidden)) > line else { return nil }
                // Only real headers (a function, class, if…), not a bare bracket or an argument list.
                let open = hidden.location - 1
                if open >= 0, open < ns.length, ns.character(at: open) == 40 || ns.character(at: open) == 91 { return nil }
                let text = ns.substring(with: ns.lineRange(for: NSRange(location: idx.starts[start], length: 0)))
                return text.contains(where: \.isLetter) ? start : nil
            }.sorted()
        }
        // The headers themselves cover the first lines, so look again below them (as VS Code does).
        let top = visible.minY + scrollView.contentView.contentInsets.top
        var lines: [Int] = []
        for _ in 0..<4 {
            let next = Array(scopes(at: lineAt(top + CGFloat(lines.count) * lineHeight + 1)).suffix(3))
            if next == lines { break }
            lines = next
        }
        let font = tv.font ?? Prefs.shared.editorFont
        let entries: [(Int, NSAttributedString)] = lines.map { l in
            let r = ns.lineRange(for: NSRange(location: idx.starts[l], length: 0))
            let line = NSMutableAttributedString(string: ns.substring(with: r).trimmingCharacters(in: .newlines),
                                                 attributes: [.font: font, .foregroundColor: Theme.current.text])
            // Same colours as the editor (syntax colours are temporary attributes on the layout manager).
            var i = r.location
            while i < NSMaxRange(r) - 1 {
                var eff = NSRange()
                if let c = lm.temporaryAttribute(.foregroundColor, atCharacterIndex: i, effectiveRange: &eff) as? NSColor {
                    let a = max(eff.location, r.location) - r.location, b = min(NSMaxRange(eff), NSMaxRange(r) - 1) - r.location
                    if b > a && b <= line.length { line.addAttribute(.foregroundColor, value: c, range: NSRange(location: a, length: b - a)) }
                }
                i = max(i + 1, NSMaxRange(eff))
            }
            return (l, line)
        }
        // The line-number gutter overlays the clip view, so align by document coordinates.
        let clip = scrollView.contentView
        let gutter = scrollView.verticalRulerView?.ruleThickness ?? 0
        let textX = tv.textContainerOrigin.x + (tv.textContainer?.lineFragmentPadding ?? 0) - clip.bounds.minX
        sticky.frame.origin.x = clip.frame.minX
        sticky.frame.origin.y = scrollView.isFlipped ? clip.frame.minY + clip.contentInsets.top : clip.frame.maxY - clip.contentInsets.top - sticky.frame.height
        sticky.frame.size.width = clip.frame.width
        sticky.update(entries, lineHeight: lineHeight, gutter: scrollView.rulersVisible ? gutter : 0, textX: textX)
    }
}

extension EditorController {
    /// The line-number gutter floats over the clip view and AppKit adds its width as a left content inset —
    /// but an editor created before its window existed (restored tabs) keeps x = 0, hiding the first
    /// characters under the gutter. Snap back to the left edge unless the user scrolled sideways.
    func fixHorizontalOrigin() {
        let clip = scrollView.contentView
        let inset = clip.contentInsets.left
        guard inset > 0, clip.bounds.minX > -inset + 0.5, clip.bounds.minX <= 0.5 else { return }
        clip.scroll(to: NSPoint(x: -inset, y: clip.bounds.minY))
        scrollView.reflectScrolledClipView(clip)
    }
}
