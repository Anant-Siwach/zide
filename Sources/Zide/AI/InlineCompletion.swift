import AppKit

// MARK: - Inline completions: after a pause in typing, the AI suggests the rest of the line (or a few lines) as grey
// ghost text at the caret. Tab inserts it, Esc or any other key dismisses it. Off unless turned on in AI Settings.

@MainActor
final class GhostText {
    private weak var textView: CodeTextView?
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private let view = GhostView()
    private(set) var suggestion: String?
    private var anchor = 0                 // caret location the suggestion belongs to
    private var anchorLength = 0           // document length then (any edit invalidates it)

    init(_ tv: CodeTextView) { textView = tv }

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "aiInlineCompletions") && AIConfig.isConfigured }
    var isVisible: Bool { suggestion != nil }

    /// Called after each typed character.
    func typed() {
        hide()
        guard Self.enabled, let tv = textView, tv.selectedRange().length == 0, (tv.string as NSString).length < 2_000_000 else { return }
        let loc = tv.selectedRange().location
        let ns = tv.string as NSString
        // Only at the end of a line (or before closing brackets / quotes), like other editors.
        let lineEnd = ns.lineRange(for: NSRange(location: loc, length: 0))
        let rest = ns.substring(with: NSRange(location: loc, length: NSMaxRange(lineEnd) - loc)).trimmingCharacters(in: .newlines)
        guard rest.allSatisfy({ ")]}\"'`;, \t".contains($0) }) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.request() } }
    }

    private func request() {
        guard let tv = textView, let doc = tv.controller?.document else { return }
        let ns = tv.string as NSString
        let loc = tv.selectedRange().location
        let prefix = ns.substring(with: NSRange(location: max(0, loc - 4000), length: min(4000, loc)))
        let suffix = ns.substring(with: NSRange(location: loc, length: min(1500, ns.length - loc)))
        guard prefix.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else { return }
        anchor = loc; anchorLength = ns.length
        let name = doc.url.lastPathComponent, lang = doc.language.name
        task?.cancel()
        task = Task {
            let system = """
            You are a code completion engine inside an editor. Output ONLY the text to insert at <CURSOR> — no explanations, \
            no code fences, no repetition of text before the cursor. Usually finish the current line; add a few more lines only \
            when the next lines are clearly implied. If nothing sensible fits, output nothing.
            """
            let user = "File: \(name) (\(lang))\n\(prefix)<CURSOR>\(suffix)"
            guard let reply = try? await AIClient.chat(system: system, messages: [AIMessage(role: "user", text: user)], maxTokens: 220), !Task.isCancelled else { return }
            let text = Self.clean(reply, prefix: prefix, suffix: suffix)
            guard !text.isEmpty, let tv = self.textView, tv.selectedRange() == NSRange(location: anchor, length: 0), (tv.string as NSString).length == anchorLength else { return }
            show(text)
        }
    }

    /// Strips fences, echoed prefix and anything the suffix already has.
    nonisolated static func clean(_ reply: String, prefix: String, suffix: String) -> String {
        var t = reply.replacingOccurrences(of: "<CURSOR>", with: "")
        if t.hasPrefix("```") { t = t.components(separatedBy: "\n").dropFirst().joined(separator: "\n") }
        if let r = t.range(of: "```", options: .backwards) { t = String(t[..<r.lowerBound]) }
        // The model sometimes repeats what's already typed: the whole line, or the end of it ("foo" in "x = foo").
        let lineStart = prefix.components(separatedBy: "\n").last ?? ""
        let trimmed = lineStart.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, t.trimmingCharacters(in: .whitespaces).hasPrefix(trimmed) {
            t = String(t.trimmingCharacters(in: .whitespaces).dropFirst(trimmed.count))
        } else {
            for k in stride(from: min(lineStart.count, t.count), through: 2, by: -1) where lineStart.hasSuffix(t.prefix(k)) {
                t = String(t.dropFirst(k)); break
            }
        }
        t = t.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        let lines = t.components(separatedBy: "\n")
        if lines.count > 12 { t = lines.prefix(12).joined(separator: "\n") }
        // Don't duplicate closing characters that follow the caret.
        let after = suffix.components(separatedBy: "\n").first ?? ""
        let close = after.trimmingCharacters(in: .whitespaces)
        if !close.isEmpty, t.hasSuffix(close) { t = String(t.dropLast(close.count)) }
        return t
    }

    private func show(_ text: String) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        suggestion = text
        let ns = tv.string as NSString
        let caretRect: NSRect = {
            if anchor < ns.length || ns.length == 0 {
                let g = lm.glyphIndexForCharacter(at: min(anchor, max(0, ns.length - 1)))
                var r = lm.boundingRect(forGlyphRange: NSRange(location: g, length: anchor < ns.length ? 0 : 1), in: tc)
                if anchor >= ns.length { r.origin.x = r.maxX }
                return r
            }
            let g = lm.glyphIndexForCharacter(at: ns.length - 1)
            var r = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
            r.origin.x = r.maxX
            return r
        }()
        let origin = tv.textContainerOrigin
        let lines = text.components(separatedBy: "\n")
        // Below the caret line there may be other code: show extra lines only if the next line is empty.
        let nextLineEmpty: Bool = {
            let lr = ns.lineRange(for: NSRange(location: anchor, length: 0))
            guard NSMaxRange(lr) < ns.length else { return true }
            let next = ns.lineRange(for: NSRange(location: NSMaxRange(lr), length: 0))
            return ns.substring(with: next).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }()
        view.lines = nextLineEmpty || lines.count == 1 ? lines : [lines[0] + "  ⋯ +\(lines.count - 1) lines (Tab)"]
        view.font = tv.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.firstX = caretRect.minX + origin.x
        view.lineX = origin.x + tc.lineFragmentPadding
        view.lineHeight = max(caretRect.height, lm.defaultLineHeight(for: view.font))
        let width = max(400, tv.bounds.width)
        view.frame = NSRect(x: 0, y: caretRect.minY + origin.y, width: width, height: view.lineHeight * CGFloat(view.lines.count) + 4)
        view.color = NSColor.secondaryLabelColor.withAlphaComponent(0.55)
        if view.superview !== tv { tv.addSubview(view) }
        view.needsDisplay = true
    }

    func hide() {
        timer?.invalidate(); timer = nil
        task?.cancel(); task = nil
        guard suggestion != nil else { return }
        suggestion = nil
        view.removeFromSuperview()
    }

    /// Tab: insert the suggestion.
    func accept() -> Bool {
        guard let s = suggestion, let tv = textView else { return false }
        hide()
        let r = tv.selectedRange()
        guard tv.shouldChangeText(in: r, replacementString: s) else { return false }
        tv.textStorage?.replaceCharacters(in: r, with: s)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: r.location + (s as NSString).length, length: 0))
        return true
    }
}

/// Draws the ghost lines: the first from the caret, the rest from the line start.
final class GhostView: NSView {
    var lines: [String] = []
    var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    var color = NSColor.secondaryLabelColor
    var firstX: CGFloat = 0, lineX: CGFloat = 0, lineHeight: CGFloat = 16
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        for (i, l) in lines.enumerated() {
            (l as NSString).draw(at: NSPoint(x: i == 0 ? firstX : lineX, y: CGFloat(i) * lineHeight), withAttributes: attrs)
        }
    }
}
