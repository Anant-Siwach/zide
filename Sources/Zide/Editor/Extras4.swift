import AppKit
import PDFKit
import SwiftUI

// Image/PDF viewer, tag auto-close, Markdown list continuation, whitespace display, inline maths, Dock menu.

// MARK: - Images and PDFs open as pictures, not "(Binary file)"

enum MediaKind { case image, pdf }

extension URL {
    var mediaKind: MediaKind? {
        switch pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "ico", "icns": return .image
        case "pdf": return .pdf
        default: return nil
        }
    }
}

struct MediaViewer: View {
    let url: URL
    @State private var info = ""

    var body: some View {
        VStack(spacing: 0) {
            MediaRepresentable(url: url, info: $info)
            HStack {
                Text(info).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open in Preview") { NSWorkspace.shared.open(url) }.buttonStyle(.borderless).font(.caption)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
    }
}

private struct MediaRepresentable: NSViewRepresentable {
    let url: URL
    @Binding var info: String

    func makeNSView(context: Context) -> NSView {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        let bytes = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        if url.mediaKind == .pdf {
            let v = PDFView()
            v.autoScales = true
            v.backgroundColor = Theme.current.background
            if let d = PDFDocument(url: url) {
                v.document = d
                DispatchQueue.main.async { info = "PDF · \(d.pageCount) page\(d.pageCount == 1 ? "" : "s") · \(bytes)" }
            } else { DispatchQueue.main.async { info = "Couldn't read this PDF · \(bytes)" } }
            return v
        }
        let scroll = NSScrollView()
        scroll.contentView = CenteringClipView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.allowsMagnification = true; scroll.minMagnification = 0.05; scroll.maxMagnification = 16
        scroll.backgroundColor = Theme.current.background
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.animates = true
        if let img = NSImage(contentsOf: url) {
            let px = img.representations.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) }.max { $0.width < $1.width } ?? img.size
            iv.image = img
            iv.frame = NSRect(origin: .zero, size: img.size)
            DispatchQueue.main.async { info = "\(Int(px.width)) × \(Int(px.height)) px · \(bytes) · pinch or ⌘-scroll to zoom" }
        } else { DispatchQueue.main.async { info = "Couldn't read this image · \(bytes)" } }
        scroll.documentView = iv
        // Fit big images on open; small ones stay at 1:1.
        DispatchQueue.main.async {
            let avail = scroll.contentSize, s = iv.frame.size
            if s.width > 0, s.height > 0 { scroll.magnification = min(1, avail.width / s.width, avail.height / s.height) }
        }
        return scroll
    }

    func updateNSView(_ v: NSView, context: Context) {}
}

/// Keeps a picture smaller than the window in the middle instead of the bottom-left corner.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposed)
        guard let doc = documentView else { return r }
        if r.width > doc.frame.width { r.origin.x = (doc.frame.width - r.width) / 2 }
        if r.height > doc.frame.height { r.origin.y = (doc.frame.height - r.height) / 2 }
        return r
    }
}

// MARK: - Editing helpers

extension CodeTextView {
    private static let voidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr", "!doctype"]

    /// Typing `>` after `<div class="x"` adds `</div>` after the caret.
    func autoCloseTag(_ s: String, _ sel: NSRange) -> Bool {
        guard s == ">", sel.length == 0, prefs.autoClosePairs else { return false }
        let jsx = ["javascriptreact", "typescriptreact"].contains(lang.id)
        guard lang.lexer == .markup || jsx else { return false }
        let ns = string as NSString
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let before = ns.substring(with: NSRange(location: line.location, length: sel.location - line.location))
        guard let m = before.firstMatch(of: #/(^|[^\w$.])<([A-Za-z][\w:.-]*)(?:\s[^<>]*)?$/#), !before.hasSuffix("/") else { return false }
        let tag = String(m.2)
        if lang.id != "xml" && Self.voidTags.contains(tag.lowercased()) { return false }
        let close = "</\(tag)>"
        let after = ns.substring(from: sel.location)
        if after.hasPrefix(close) { return false }
        super.insertText(">" + close, replacementRange: NSRange(location: NSNotFound, length: 0))
        setSelectedRange(NSRange(location: sel.location + 1, length: 0))
        controller?.typed(">")
        return true
    }

    /// Enter on a Markdown list item starts the next one (numbers count up, checkboxes stay unticked);
    /// Enter on an empty item ends the list.
    func continueMarkdownList() -> Bool {
        guard lang.lexer == .markdown || lang.id == "plaintext" else { return false }
        let sel = selectedRange()
        guard sel.length == 0 else { return false }
        let ns = string as NSString
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let before = ns.substring(with: NSRange(location: line.location, length: sel.location - line.location))
        guard let m = before.firstMatch(of: #/^(\s*)([-*+]|(\d+)([.)]))(\s+)(\[[ xX]\]\s+)?/#) else { return false }
        if before.count == m.0.count {
            // Empty item: remove the marker instead of adding another.
            let restOfLine = ns.substring(with: NSRange(location: sel.location, length: NSMaxRange(line) - sel.location)).trimmingCharacters(in: .newlines)
            guard restOfLine.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            insertText("", replacementRange: NSRange(location: line.location, length: sel.location - line.location))
            return true
        }
        var marker = String(m.2)
        if let n = m.3.flatMap({ Int($0) }), let p = m.4 { marker = "\(n + 1)\(p)" }
        insertText("\n" + m.1 + marker + m.5 + (m.6 == nil ? "" : "[ ] "), replacementRange: sel)
        scrollRangeToVisible(selectedRange())
        return true
    }

    /// Faint · for spaces and → for tabs in the visible text (View ▸ Show Whitespace).
    func drawWhitespace(in rect: NSRect) {
        guard prefs.showWhitespace, let lm = layoutManager, let tc = textContainer else { return }
        var vis = rect; vis.origin.x -= textContainerOrigin.x; vis.origin.y -= textContainerOrigin.y
        let glyphs = lm.glyphRange(forBoundingRect: vis, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard chars.length < 60_000 else { return }
        let ns = string as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: Theme.current.text.withAlphaComponent(0.25)]
        let dot = NSAttributedString(string: "·", attributes: attrs), arrow = NSAttributedString(string: "→", attributes: attrs)
        for i in chars.location..<NSMaxRange(chars) {
            let c = ns.character(at: i)
            guard c == 32 || c == 9 else { continue }
            let g = lm.glyphIndexForCharacter(at: i)
            var r = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
            r.origin.x += textContainerOrigin.x; r.origin.y += textContainerOrigin.y
            let mark = c == 32 ? dot : arrow
            let sz = mark.size()
            mark.draw(at: NSPoint(x: c == 32 ? r.midX - sz.width / 2 : r.minX + 1, y: r.midY - sz.height / 2))
        }
    }

    @objc func toggleShowWhitespace(_ sender: Any?) { Prefs.shared.showWhitespace.toggle() }

    /// ⌃⌥= : works out the maths in the selection, or on the current line, and writes "= answer" after it.
    @objc func evaluateMath(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        var exprRange = sel
        if sel.length == 0 {
            let line = ns.lineRange(for: sel)
            var end = NSMaxRange(line)
            while end > line.location, [10, 13].contains(ns.character(at: end - 1)) { end -= 1 }
            exprRange = NSRange(location: line.location, length: end - line.location)
        }
        var text = ns.substring(with: exprRange)
        // On a line like "rent: 1200 * 12 =", use what's after the label and fill in after the "=".
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        let endsWithEquals = trimmed.hasSuffix("=")
        if endsWithEquals { trimmed.removeLast() }
        if let colon = trimmed.lastIndex(of: ":"), Calc.evaluate(String(trimmed[trimmed.index(after: colon)...])) != nil { trimmed = String(trimmed[trimmed.index(after: colon)...]) }
        guard let v = Calc.evaluate(trimmed) else { NSSound.beep(); return }
        text = Calc.format(v)
        let insertAt = NSMaxRange(exprRange)
        let lineEnd = ns.substring(with: exprRange)
        let out = endsWithEquals ? (lineEnd.hasSuffix(" ") ? "" : " ") + text : " = " + text
        insertText(out, replacementRange: NSRange(location: insertAt, length: 0))
        undoManager?.setActionName("Evaluate")
    }
}

/// A small, safe calculator: + − × ÷ % ^, brackets, decimals, thousands separators.
enum Calc {
    static func evaluate(_ s: String) -> Double? {
        var t = s.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: "−", with: "-")
        t = t.replacingOccurrences(of: #"(?<=\d),(?=\d{3})"#, with: "", options: .regularExpression).replacingOccurrences(of: "_", with: "")
        let chars = Array(t.filter { !$0.isWhitespace && $0 != "$" && $0 != "€" && $0 != "£" && $0 != "₹" })
        guard !chars.isEmpty, chars.contains(where: { "+-*/%^".contains($0) }) || chars.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        var i = 0
        func peek() -> Character? { i < chars.count ? chars[i] : nil }
        func number() -> Double? {
            let start = i
            while let c = peek(), c.isNumber || c == "." { i += 1 }
            return i > start ? Double(String(chars[start..<i])) : nil
        }
        func factor() -> Double? {
            if peek() == "-" { i += 1; return factor().map { -$0 } }
            if peek() == "+" { i += 1; return factor() }
            var base: Double?
            if peek() == "(" { i += 1; base = expr(); guard peek() == ")" else { return nil }; i += 1 } else { base = number() }
            guard var b = base else { return nil }
            if peek() == "%" , i + 1 >= chars.count || ")+-*/".contains(chars[i + 1]) { i += 1; b /= 100 }
            if peek() == "^" { i += 1; guard let e = factor() else { return nil }; b = pow(b, e) }
            return b
        }
        func term() -> Double? {
            guard var v = factor() else { return nil }
            while let c = peek(), c == "*" || c == "/" || c == "%" {
                i += 1
                guard let r = factor() else { return nil }
                v = c == "*" ? v * r : c == "/" ? v / r : v.truncatingRemainder(dividingBy: r)
            }
            return v
        }
        func expr() -> Double? {
            guard var v = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                i += 1
                guard let r = term() else { return nil }
                v = c == "+" ? v + r : v - r
            }
            return v
        }
        guard let v = expr(), i == chars.count, v.isFinite else { return nil }
        return v
    }

    static func format(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        let f = NumberFormatter()
        f.numberStyle = .decimal; f.usesGroupingSeparator = false
        f.maximumSignificantDigits = 12; f.usesSignificantDigits = true
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
}

// MARK: - Dock menu: recent files and a quick note

extension AppDelegate {
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        let note = NSMenuItem(title: "New Quick Note", action: #selector(newQuickNote(_:)), keyEquivalent: "")
        note.target = self
        m.addItem(note)
        let recent = Prefs.shared.recentFiles.prefix(10)
        if !recent.isEmpty {
            m.addItem(.separator())
            for url in recent {
                let it = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecentFromDock(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = url
                it.toolTip = url.path
                it.image = NSWorkspace.shared.icon(forFile: url.path)
                it.image?.size = NSSize(width: 16, height: 16)
                m.addItem(it)
            }
        }
        return m
    }

    @objc func openRecentFromDock(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openPath(url)
        NSApp.activate(ignoringOtherApps: true)
    }
}
