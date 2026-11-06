import AppKit
import SwiftUI

// Links, colour swatches, per-file wrap, status-bar conversions, Markdown outline, date insertion.

extension EditorDocument {
    /// nil = automatic (wrap prose, follow the setting for code).
    var effectiveWrap: Bool { softWrap ?? (Prefs.shared.wordWrap || language.isProse) }

    func setLineEnding(_ e: String) {
        guard e != lineEnding else { return }
        objectWillChange.send()
        lineEnding = e
        markEdited()
    }

    func setEncoding(_ e: String.Encoding) {
        guard e != encoding else { return }
        objectWillChange.send()
        encoding = e
        markEdited()
    }

    func setIndent(spaces: Bool, width: Int) {
        objectWillChange.send()
        detectedIndent = (spaces, width)
        NotificationCenter.default.post(name: Prefs.editorChanged, object: nil)
    }

    func toggleWrap() {
        objectWillChange.send()
        softWrap = !effectiveWrap
        NotificationCenter.default.post(name: Prefs.editorChanged, object: nil)
    }
}

extension EditorController {
    /// URLs underlined (⌘-click opens), CSS-style colours shown in their own colour (⌘-click edits).
    func decorateLinksAndColors(length: Int) {
        guard let doc = document, length < 600_000 else { linkRanges = []; colorSpans = []; return }
        let ns = doc.storage.string as NSString
        let lm = layoutManager
        var links: [NSRange] = []
        if let re = try? NSRegularExpression(pattern: #"\bhttps?://[^\s<>"'`)\]]+[^\s<>"'`)\].,;:!?]"#) {
            re.enumerateMatches(in: ns as String, range: NSRange(location: 0, length: length)) { m, _, _ in
                guard let r = m?.range else { return }
                links.append(r)
                lm.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: Theme.current.accent.withAlphaComponent(0.6)], forCharacterRange: r)
            }
        }
        linkRanges = links
        var colors: [(NSRange, NSColor)] = []
        let colorLangs: Set<String> = ["css", "scss", "less", "html", "svelte", "vue", "javascript", "typescript", "javascriptreact", "typescriptreact", "json", "yaml", "toml", "swift", "kotlin", "dart", "markdown"]
        if colorLangs.contains(doc.language.id), let re = try? NSRegularExpression(pattern: #"#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3,4})\b|rgba?\(\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\s*(?:,\s*[\d.]+\s*)?\)"#) {
            re.enumerateMatches(in: ns as String, range: NSRange(location: 0, length: length)) { m, _, _ in
                guard let r = m?.range, let c = Self.parseColor(ns.substring(with: r)) else { return }
                // #abc inside an identifier or URL fragment isn't a colour.
                if r.location > 0, let prev = UnicodeScalar(ns.character(at: r.location - 1)), CharacterSet.alphanumerics.contains(prev) || prev == "&" { return }
                colors.append((r, c))
                let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
                let fg: NSColor = c.alphaComponent < 0.4 ? Theme.current.text : (lum > 0.6 ? .black : .white)
                lm.addTemporaryAttributes([.backgroundColor: c, .foregroundColor: fg], forCharacterRange: r)
            }
        }
        colorSpans = colors
    }

    static func parseColor(_ s: String) -> NSColor? {
        if s.hasPrefix("#") {
            var h = String(s.dropFirst())
            if h.count == 3 || h.count == 4 { h = h.map { "\($0)\($0)" }.joined() }
            guard let v = UInt64(h, radix: 16) else { return nil }
            let has = h.count == 8
            let r = has ? (v >> 24) & 0xff : (v >> 16) & 0xff, g = has ? (v >> 16) & 0xff : (v >> 8) & 0xff, b = has ? (v >> 8) & 0xff : v & 0xff
            let a = has ? v & 0xff : 255
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
        }
        let nums = s.split(whereSeparator: { !"0123456789.".contains($0) }).compactMap { Double($0) }
        guard nums.count >= 3 else { return nil }
        return NSColor(srgbRed: nums[0] / 255, green: nums[1] / 255, blue: nums[2] / 255, alpha: nums.count > 3 ? nums[3] : 1)
    }

    static func hex(_ c: NSColor, alpha: Bool) -> String {
        let c = c.usingColorSpace(.sRGB) ?? c
        let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded()), b = Int((c.blueComponent * 255).rounded())
        let a = Int((c.alphaComponent * 255).rounded())
        return alpha || a < 255 ? String(format: "#%02x%02x%02x%02x", r, g, b, a) : String(format: "#%02x%02x%02x", r, g, b)
    }
}

/// Edits a colour in the text from the system colour panel.
@MainActor
final class ColorEditTarget: NSObject {
    static let shared = ColorEditTarget()
    weak var textView: CodeTextView?
    var range = NSRange()
    var wasRGB = false

    func edit(_ tv: CodeTextView, range: NSRange, color: NSColor, original: String) {
        textView = tv; self.range = range; wasRGB = original.hasPrefix("rgb")
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.setTarget(nil); panel.setAction(nil)
        panel.color = color
        panel.setTarget(self); panel.setAction(#selector(changed(_:)))
        panel.orderFront(nil)
    }

    @objc func changed(_ panel: NSColorPanel) {
        guard let tv = textView, NSMaxRange(range) <= (tv.string as NSString).length else { return }
        let c = panel.color.usingColorSpace(.sRGB) ?? panel.color
        let text: String
        if wasRGB {
            let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded()), b = Int((c.blueComponent * 255).rounded())
            text = c.alphaComponent < 1 ? "rgba(\(r), \(g), \(b), \(String(format: "%.2g", c.alphaComponent)))" : "rgb(\(r), \(g), \(b))"
        } else {
            text = EditorController.hex(c, alpha: false)
        }
        if tv.shouldChangeText(in: range, replacementString: text) {
            tv.textStorage?.replaceCharacters(in: range, with: text)
            tv.didChangeText()
            range.length = (text as NSString).length
        }
    }
}

extension CodeTextView {
    /// ⌘-click on a link opens it; on a colour, edits it. Returns true when handled.
    func handleCommandClick(at idx: Int) -> Bool {
        guard let c = controller else { return false }
        if let r = c.linkRanges.first(where: { NSLocationInRange(idx, $0) }), let url = URL(string: (string as NSString).substring(with: r)) {
            NSWorkspace.shared.open(url); return true
        }
        if let (r, col) = c.colorSpans.first(where: { NSLocationInRange(idx, $0.0) || NSMaxRange($0.0) == idx }) {
            ColorEditTarget.shared.edit(self, range: r, color: col, original: (string as NSString).substring(with: r)); return true
        }
        return false
    }

    @objc func insertDateTime(_ sender: Any?) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        insertText(f.string(from: Date()), replacementRange: selectedRange())
    }

    @objc func toggleSoftWrap(_ sender: Any?) { controller?.document?.toggleWrap() }
}

/// Markdown headings as the Structure outline when there's no language server answer.
@MainActor
enum MarkdownOutline {
    static func symbols(_ doc: EditorDocument) -> [DocSymbol] {
        guard doc.language.lexer == .markdown else { return [] }
        let ns = doc.storage.string as NSString
        guard let re = try? NSRegularExpression(pattern: #"^(#{1,6})[ \t]+(.+?)[ \t#]*$"#, options: .anchorsMatchLines) else { return [] }
        var out: [DocSymbol] = []
        var inFence = false
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { line, r, _, _ in
            guard let line else { return }
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); return }
            guard !inFence, let m = re.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return }
            let level = m.range(at: 1).length
            out.append(DocSymbol(name: (line as NSString).substring(with: m.range(at: 2)), detail: "", kind: 15,
                                 range: NSRange(location: r.location + m.range(at: 2).location, length: m.range(at: 2).length), depth: level - 1))
        }
        return out
    }
}

/// Status-bar menus: line endings, encoding, indentation, wrap.
struct DocFormatMenus: View {
    @ObservedObject var doc: EditorDocument

    var body: some View {
        Menu(doc.effectiveWrap ? "Wrap" : "No Wrap") {
            Button(doc.effectiveWrap ? "Turn Soft Wrap Off" : "Turn Soft Wrap On") { doc.toggleWrap() }
        }
        .menuStyle(.borderlessButton).fixedSize().help("Soft wrap for this file (⌥Z)")
        Menu(doc.lineEnding == "\r\n" ? "CRLF" : "LF") {
            Button("LF — macOS / Linux") { doc.setLineEnding("\n") }
            Button("CRLF — Windows") { doc.setLineEnding("\r\n") }
        }
        .menuStyle(.borderlessButton).fixedSize().help("Line endings (converted on save)")
        Menu(doc.encoding == .utf8 ? "UTF-8" : doc.encoding == .utf16 ? "UTF-16" : "ISO-8859-1") {
            Button("UTF-8") { doc.setEncoding(.utf8) }
            Button("UTF-16") { doc.setEncoding(.utf16) }
            Button("ISO-8859-1 (Latin-1)") { doc.setEncoding(.isoLatin1) }
        }
        .menuStyle(.borderlessButton).fixedSize().help("Encoding used when saving")
        Menu(doc.insertSpaces ? "\(doc.tabWidth) spaces" : "Tab") {
            ForEach([2, 4, 8], id: \.self) { w in Button("\(w) spaces") { doc.setIndent(spaces: true, width: w) } }
            Button("Tabs") { doc.setIndent(spaces: false, width: Prefs.shared.tabWidth) }
        }
        .menuStyle(.borderlessButton).fixedSize().help(doc.detectedIndent == nil ? "Indentation (from Settings)" : "Indentation (detected in this file)")
    }
}
