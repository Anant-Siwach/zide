import AppKit

extension NSAttributedString.Key {
    /// Inlay hint label attached to the character the hint follows (paired with .kern to make room).
    static let zideInlayHint = NSAttributedString.Key("ZideInlayHint")
}

/// Inlay hints (parameter names, inferred types) from the language server.
extension EditorDocument {
    static let hintFont = NSFont.systemFont(ofSize: 11, weight: .regular)

    func refreshInlayHints() {
        guard Prefs.shared.inlayHints, !isTooLarge, storage.length < 400_000, let ws = workspace,
              let client = ws.lsp.client(of: self), client.supports("inlayHintProvider") else { clearInlayHints(); return }
        let version = self.version
        let full = lineIndex.lspRange(NSRange(location: 0, length: storage.length))
        Task {
            let r = await ws.lsp.request("textDocument/inlayHint", self, params: ["range": full]) as? [JSON]
            guard self.version == version, let hints = r else { return }
            self.applyInlayHints(hints)
        }
    }

    private func applyInlayHints(_ hints: [JSON]) {
        let idx = lineIndex
        storage.beginEditing()
        removeHintAttributes()
        let font = Self.hintFont
        for h in hints.prefix(3000) {
            guard let pos = h["position"] as? JSON else { continue }
            let offset = idx.offset(line: pos["line"] as? Int ?? 0, character: pos["character"] as? Int ?? 0)
            guard offset > 0, offset <= storage.length else { continue }
            var label: String
            if let s = h["label"] as? String { label = s } else { label = ((h["label"] as? [JSON]) ?? []).compactMap { $0["value"] as? String }.joined() }
            label = label.trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, label.count < 60 else { continue }
            let width = (label as NSString).size(withAttributes: [.font: font]).width + 12
            let r = NSRange(location: offset - 1, length: 1)
            // Don't put hints after a newline (would shift the next line).
            if (storage.string as NSString).character(at: offset - 1) == 10 { continue }
            storage.addAttributes([.kern: width, .zideInlayHint: label], range: r)
        }
        storage.endEditing()
        editors.forEach { $0.textView.needsDisplay = true }
    }

    func clearInlayHints() {
        storage.beginEditing()
        removeHintAttributes()
        storage.endEditing()
    }

    private func removeHintAttributes() {
        var ranges: [NSRange] = []
        storage.enumerateAttribute(.zideInlayHint, in: NSRange(location: 0, length: storage.length)) { v, r, _ in if v != nil { ranges.append(r) } }
        for r in ranges { storage.removeAttribute(.kern, range: r); storage.removeAttribute(.zideInlayHint, range: r) }
    }
}

extension CodeTextView {
    func drawInlayHints(in rect: NSRect) {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return }
        let glyphs = lm.glyphRange(forBoundingRect: rect, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard chars.length > 0 else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: EditorDocument.hintFont, .foregroundColor: Theme.isDark ? Palette.hex("8C8F96") : Palette.hex("7A7E85")]
        let bg = Theme.isDark ? Palette.hex("2E3035") : Palette.hex("EEF0F4")
        storage.enumerateAttribute(.zideInlayHint, in: chars) { v, r, _ in
            guard let label = v as? String, NSMaxRange(r) <= storage.length else { return }
            let g = lm.glyphIndexForCharacter(at: r.location)
            if lm.propertyForGlyph(at: g) == .null { return }   // inside a fold
            let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let glyphX = lm.location(forGlyphAt: g).x + frag.minX
            let kern = (storage.attribute(.kern, at: r.location, effectiveRange: nil) as? CGFloat) ?? 0
            // The gap sits between this glyph and the next one; anchor to the next glyph's position.
            var endX = glyphX + lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc).width
            if g + 1 < lm.numberOfGlyphs {
                let nextFrag = lm.lineFragmentRect(forGlyphAt: g + 1, effectiveRange: nil)
                if nextFrag.minY == frag.minY { endX = lm.location(forGlyphAt: g + 1).x + nextFrag.minX }
            }
            let x = endX - kern + 4 + textContainerOrigin.x
            let size = (label as NSString).size(withAttributes: attrs)
            let box = NSRect(x: x, y: frag.minY + textContainerOrigin.y + (frag.height - size.height - 2) / 2, width: size.width + 6, height: size.height + 2)
            bg.setFill()
            NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
            (label as NSString).draw(at: NSPoint(x: box.minX + 3, y: box.minY + 1), withAttributes: attrs)
        }
    }
}
