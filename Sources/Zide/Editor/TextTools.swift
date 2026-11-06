import AppKit

/// Edit ▸ Transform: everyday text jobs on the selection (or the whole file when nothing is selected).
extension CodeTextView {
    /// Replaces the selected lines (whole lines; whole file if the selection is empty) through `f`, undoably.
    private func transformLines(_ name: String, _ f: ([String]) -> [String]) {
        transform(name, lines: true) { s in
            let trailing = s.hasSuffix("\n")
            var lines = s.components(separatedBy: "\n")
            if trailing { lines.removeLast() }
            return f(lines).joined(separator: "\n") + (trailing ? "\n" : "")
        }
    }

    private func transform(_ name: String, lines: Bool = false, _ f: (String) -> String?) {
        let ns = string as NSString
        var r = selectedRange()
        if r.length == 0 { r = NSRange(location: 0, length: ns.length) }
        else if lines { r = ns.lineRange(for: r) }
        guard let out = f(ns.substring(with: r)) else { NSSound.beep(); return }
        guard out != ns.substring(with: r), shouldChangeText(in: r, replacementString: out) else { return }
        textStorage?.replaceCharacters(in: r, with: out)
        didChangeText()
        undoManager?.setActionName(name)
        setSelectedRange(NSRange(location: r.location, length: (out as NSString).length))
    }

    @objc func sortLines(_ sender: Any?) { transformLines("Sort Lines") { $0.sorted { $0.localizedStandardCompare($1) == .orderedAscending } } }
    @objc func sortLinesDescending(_ sender: Any?) { transformLines("Sort Lines") { $0.sorted { $0.localizedStandardCompare($1) == .orderedDescending } } }
    @objc func reverseLines(_ sender: Any?) { transformLines("Reverse Lines") { $0.reversed() } }
    @objc func shuffleLines(_ sender: Any?) { transformLines("Shuffle Lines") { $0.shuffled() } }
    @objc func uniqueLines(_ sender: Any?) { transformLines("Remove Duplicate Lines") { var seen = Set<String>(); return $0.filter { seen.insert($0).inserted } } }
    @objc func removeBlankLines(_ sender: Any?) { transformLines("Remove Blank Lines") { $0.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } } }
    @objc func trimLines(_ sender: Any?) { transformLines("Trim Whitespace") { $0.map { $0.trimmingCharacters(in: .whitespaces) } } }
    @objc func joinLines(_ sender: Any?) { transform("Join Lines", lines: true) { s in
        let parts = s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.joined(separator: " ") + (s.hasSuffix("\n") ? "\n" : "")
    } }
    @objc func upperCase(_ sender: Any?) { transform("Uppercase") { $0.uppercased() } }
    @objc func lowerCase(_ sender: Any?) { transform("Lowercase") { $0.lowercased() } }
    @objc func titleCase(_ sender: Any?) { transform("Title Case") { $0.capitalized } }
    @objc func camelSnakeToggle(_ sender: Any?) { transform("camelCase ↔ snake_case") { s in
        if s.contains("_") {
            let p = s.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
            return p.enumerated().map { $0.offset == 0 ? $0.element.lowercased() : $0.element.capitalized }.joined()
        }
        return s.replacing(#/([a-z0-9])([A-Z])/#) { "\($0.1)_\($0.2)" }.lowercased()
    } }
    @objc func prettyJSON(_ sender: Any?) { transform("Format JSON") { s in
        guard let o = try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed]),
              let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) else { return nil }
        return String(decoding: d, as: UTF8.self)
    } }
    @objc func minifyJSON(_ sender: Any?) { transform("Minify JSON") { s in
        guard let o = try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed]),
              let d = try? JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes, .fragmentsAllowed]) else { return nil }
        return String(decoding: d, as: UTF8.self)
    } }
    @objc func base64Encode(_ sender: Any?) { transform("Base64 Encode") { Data($0.utf8).base64EncodedString() } }
    @objc func base64Decode(_ sender: Any?) { transform("Base64 Decode") { Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { String(data: $0, encoding: .utf8) } } }
    @objc func urlEncode(_ sender: Any?) { transform("URL Encode") { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))) } }
    @objc func urlDecode(_ sender: Any?) { transform("URL Decode") { $0.removingPercentEncoding } }

    @objc func copyFilePath(_ sender: Any?) {
        guard let url = controller?.document?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }
}

extension CodeTextView {
    /// 1730000000 ⇄ 2024-10-27 03:33:20 (seconds or milliseconds; local time).
    @objc func convertTimestamp(_ sender: Any?) {
        let ns = string as NSString
        var r = selectedRange()
        if r.length == 0 {
            // The number under the caret.
            var s = r.location, e = r.location
            while s > 0, (48...57).contains(ns.character(at: s - 1)) { s -= 1 }
            while e < ns.length, (48...57).contains(ns.character(at: e)) { e += 1 }
            r = NSRange(location: s, length: e - s)
        }
        guard r.length > 0, let out = Self.timestampSwap(ns.substring(with: r)), shouldChangeText(in: r, replacementString: out) else { NSSound.beep(); return }
        textStorage?.replaceCharacters(in: r, with: out)
        didChangeText()
        undoManager?.setActionName("Convert Timestamp")
        setSelectedRange(NSRange(location: r.location, length: (out as NSString).length))
    }

    static func timestampSwap(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if t.allSatisfy(\.isNumber), let n = Double(t), t.count == 10 || t.count == 13 {
            return f.string(from: Date(timeIntervalSince1970: t.count == 13 ? n / 1000 : n))
        }
        for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: t) { return String(Int(d.timeIntervalSince1970)) }
        }
        if let d = ISO8601DateFormatter().date(from: t) { return String(Int(d.timeIntervalSince1970)) }
        return nil
    }
}
