import AppKit

/// Gutter: breakpoints / bookmarks / execution arrow · line numbers · git change bars.
/// Click toggles a breakpoint (like JetBrains); ⇧-click selects the line.
final class LineNumberRuler: NSRulerView {
    weak var textView: CodeTextView?
    weak var document: EditorDocument?
    private let iconArea: CGFloat = 18
    private let foldArea: CGFloat = 14
    private var foldX: CGFloat { ruleThickness - 19 }

    init(textView: CodeTextView, document: EditorDocument) {
        self.textView = textView
        self.document = document
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        updateThickness()
    }

    required init(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func updateThickness() {
        let lines = document?.lineIndex.lineCount ?? 1
        let digits = max(3, String(lines).count)
        let w = iconArea + CGFloat(digits) * (Prefs.shared.editorFont.pointSize * 0.62) + 18 + foldArea
        if abs(ruleThickness - w) > 0.5 {
            ruleThickness = w
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.textView?.controller?.fixHorizontalOrigin() } }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.current.gutter.setFill()
        bounds.fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer, let doc = document else { return }
        let palette = Theme.current
        let ns = tv.string as NSString
        let index = doc.lineIndex
        let glyphs = lm.glyphRange(forBoundingRect: tv.visibleRect, in: tc)
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(9, Prefs.shared.editorFont.pointSize - 1.5), weight: .regular)
        let caretLine = index.line(of: tv.selectedRange().location)
        var severities: [Int: Diagnostic.Severity] = [:]
        for d in doc.diagnostics where d.severity.rawValue <= 2 {
            if let s = severities[d.line], s.rawValue <= d.severity.rawValue { continue }
            severities[d.line] = d.severity
        }
        let ws = doc.workspace
        let breakpoints = ws?.debug.lines(for: doc.url) ?? []
        let bookmarks = ws?.bookmarks.lines(for: doc.url) ?? []
        let changes = ws?.git.lineChanges[doc.url] ?? [:]
        let exec = tv.controller?.executionLine
        let relY = convert(NSPoint.zero, from: tv).y

        func drawLine(_ line: Int, y: CGFloat, height: CGFloat) {
            let n = line + 1
            let label = "\(n)" as NSString
            var color = line == caretLine ? palette.gutterTextActive : palette.gutterText
            if let sev = severities[line] { color = sev == .error ? palette.error : palette.warning }
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 9 - foldArea, y: y + (height - size.height) / 2), withAttributes: attrs)
            if let c = tv.controller, c.foldRegions[line] != nil {
                let folded = c.isFolded(line: line)
                let chev = NSBezierPath()
                let cx = foldX + 5, cyy = y + height / 2
                if folded { chev.move(to: NSPoint(x: cx - 2, y: cyy - 4)); chev.line(to: NSPoint(x: cx + 2, y: cyy)); chev.line(to: NSPoint(x: cx - 2, y: cyy + 4)) }
                else { chev.move(to: NSPoint(x: cx - 4, y: cyy - 2)); chev.line(to: NSPoint(x: cx, y: cyy + 2)); chev.line(to: NSPoint(x: cx + 4, y: cyy - 2)) }
                chev.lineWidth = 1.4
                (folded ? palette.accent : palette.gutterText).setStroke()
                chev.stroke()
            }
            let cy = y + height / 2
            if breakpoints.contains(n) {
                palette.error.setFill()
                NSBezierPath(ovalIn: NSRect(x: 4, y: cy - 6, width: 12, height: 12)).fill()
                if !(ws?.debug.condition(for: doc.url, line: n).isEmpty ?? true) {
                    let q = "?" as NSString
                    let qa: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .heavy), .foregroundColor: NSColor.white]
                    let qs = q.size(withAttributes: qa)
                    q.draw(at: NSPoint(x: 10 - qs.width / 2, y: cy - qs.height / 2), withAttributes: qa)
                }
            } else if bookmarks.contains(n) {
                NSColor.systemOrange.setFill()
                let p = NSBezierPath()
                p.move(to: NSPoint(x: 6, y: cy - 6)); p.line(to: NSPoint(x: 14, y: cy - 6)); p.line(to: NSPoint(x: 14, y: cy + 6))
                p.line(to: NSPoint(x: 10, y: cy + 3)); p.line(to: NSPoint(x: 6, y: cy + 6)); p.close(); p.fill()
            }
            if let t = tv.controller?.testTargets[n], !breakpoints.contains(n), !bookmarks.contains(n), exec != n {
                NSColor.systemGreen.withAlphaComponent(0.9).setFill()
                let p = NSBezierPath()
                p.move(to: NSPoint(x: 6, y: cy - 5.5)); p.line(to: NSPoint(x: 15, y: cy)); p.line(to: NSPoint(x: 6, y: cy + 5.5)); p.close(); p.fill()
                _ = t
            }
            if exec == n {
                NSColor.systemGreen.setFill()
                let p = NSBezierPath()
                p.move(to: NSPoint(x: 5, y: cy - 5)); p.line(to: NSPoint(x: 15, y: cy)); p.line(to: NSPoint(x: 5, y: cy + 5)); p.close(); p.fill()
            }
            if let change = changes[n] {
                let c: NSColor = change == .added ? palette.added : change == .modified ? palette.modified : .secondaryLabelColor
                c.setFill()
                if change == .deleted {
                    let p = NSBezierPath()
                    p.move(to: NSPoint(x: ruleThickness - 5, y: y - 3)); p.line(to: NSPoint(x: ruleThickness, y: y)); p.line(to: NSPoint(x: ruleThickness - 5, y: y + 3)); p.close(); p.fill()
                } else {
                    NSRect(x: ruleThickness - 4, y: y, width: 3, height: height).fill()
                }
            }
        }

        var lastLine = -1
        lm.enumerateLineFragments(forGlyphRange: glyphs) { frag, _, _, gr, _ in
            let line = index.line(of: lm.characterIndexForGlyph(at: gr.location))
            guard line != lastLine else { return }
            lastLine = line
            drawLine(line, y: frag.minY + tv.textContainerOrigin.y + relY, height: frag.height)
        }
        if ns.length == 0 || ns.character(at: ns.length - 1) == 10 {
            let r = lm.extraLineFragmentRect
            if !r.isEmpty { drawLine(index.lineCount - 1, y: r.minY + tv.textContainerOrigin.y + relY, height: r.height) }
        }
    }

    private func line(at event: NSEvent) -> Int? {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer, let doc = document else { return nil }
        let p = tv.convert(event.locationInWindow, from: nil)
        if lm.extraLineFragmentRect.offsetBy(dx: 0, dy: tv.textContainerOrigin.y).insetBy(dx: -10000, dy: 0).contains(NSPoint(x: 0, y: p.y)) {
            return doc.lineIndex.lineCount
        }
        let g = lm.glyphIndex(for: NSPoint(x: 0, y: p.y - tv.textContainerOrigin.y), in: tc)
        return doc.lineIndex.line(of: lm.characterIndexForGlyph(at: g)) + 1
    }

    override func mouseDown(with event: NSEvent) {
        guard let tv = textView, let doc = document, let n = line(at: event) else { return }
        if event.modifierFlags.contains(.shift) {
            let off = doc.lineIndex.offset(line: n - 1, character: 0)
            tv.setSelectedRange((tv.string as NSString).lineRange(for: NSRange(location: off, length: 0)))
            tv.window?.makeFirstResponder(tv)
            return
        }
        let x = convert(event.locationInWindow, from: nil).x
        if x >= foldX - 2 && x <= foldX + 12, let c = tv.controller, c.foldRegions[n - 1] != nil {
            c.toggleFold(line: n - 1)
            needsDisplay = true
            return
        }
        // ▶ next to a test: run just that test.
        if x <= 18, let t = tv.controller?.testTargets[n], let ws = doc.workspace {
            MainActor.assumeIsolated { ws.runner.run(RunConfig(name: "Test \(t.name)", command: t.command)) }
            return
        }
        doc.workspace?.debug.toggleBreakpoint(doc.url, line: n)
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let doc = document, let n = line(at: event), let ws = doc.workspace else { return nil }
        let m = NSMenu()
        let bp = NSMenuItem(title: ws.debug.lines(for: doc.url).contains(n) ? "Remove Breakpoint" : "Add Breakpoint", action: #selector(menuToggleBreakpoint(_:)), keyEquivalent: "")
        bp.target = self; bp.tag = n; m.addItem(bp)
        let cond = NSMenuItem(title: "Edit Breakpoint Condition…", action: #selector(menuCondition(_:)), keyEquivalent: "")
        cond.target = self; cond.tag = n; m.addItem(cond)
        if let t = (textView as? CodeTextView)?.controller?.testTargets[n] {
            let run = NSMenuItem(title: "Run '\(t.name)'", action: #selector(menuRunTest(_:)), keyEquivalent: "")
            run.target = self; run.tag = n; m.insertItem(run, at: 0); m.insertItem(.separator(), at: 1)
        }
        let bm = NSMenuItem(title: ws.bookmarks.lines(for: doc.url).contains(n) ? "Remove Bookmark" : "Add Bookmark", action: #selector(menuToggleBookmark(_:)), keyEquivalent: "")
        bm.target = self; bm.tag = n; m.addItem(bm)
        if ws.git.isRepo {
            m.addItem(.separator())
            let h = NSMenuItem(title: "Show Local History", action: #selector(menuHistory(_:)), keyEquivalent: "")
            h.target = self; m.addItem(h)
        }
        return m
    }

    @objc private func menuRunTest(_ s: NSMenuItem) {
        guard let doc = document, let t = (textView as? CodeTextView)?.controller?.testTargets[s.tag], let ws = doc.workspace else { return }
        MainActor.assumeIsolated { ws.runner.run(RunConfig(name: "Test \(t.name)", command: t.command)) }
    }
    @objc private func menuToggleBreakpoint(_ s: NSMenuItem) { if let doc = document { doc.workspace?.debug.toggleBreakpoint(doc.url, line: s.tag) } }
    @objc private func menuCondition(_ s: NSMenuItem) { if let doc = document { MainActor.assumeIsolated { doc.workspace?.debug.editCondition(doc.url, line: s.tag) } } }
    @objc private func menuToggleBookmark(_ s: NSMenuItem) { if let doc = document { doc.workspace?.bookmarks.toggle(doc.url, line: s.tag); needsDisplay = true } }
    @objc private func menuHistory(_ s: NSMenuItem) { if let doc = document { MainActor.assumeIsolated { LocalHistoryWindow.show(doc) } } }
}
