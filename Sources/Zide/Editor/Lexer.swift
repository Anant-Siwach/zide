import Foundation

struct Token {
    var start: Int32
    var length: Int32
    var kind: TokenKind
    var range: NSRange { NSRange(location: Int(start), length: Int(length)) }
}

/// A fast single-pass tokenizer driven by `Language` tables. Works on UTF-16 so ranges map directly to NSString.
struct Lexer {
    let lang: Language
    private let s: [UInt16]
    private let n: Int
    private(set) var tokens: [Token] = []
    private let kw: Set<String>, types: Set<String>, consts: Set<String>, builtins: Set<String>
    private let stringDelims: [[UInt16]]
    private let multi: Set<[UInt16]>
    private let lineComment: [UInt16]?
    private let blockStart: [UInt16]?, blockEnd: [UInt16]?

    init(lang: Language, text: [UInt16]) {
        self.lang = lang
        s = text
        n = text.count
        let fold: (Set<String>) -> Set<String> = { lang.caseInsensitive ? Set($0.map { $0.lowercased() }) : $0 }
        kw = fold(lang.keywords); types = fold(lang.types); consts = fold(lang.constants); builtins = lang.builtins
        stringDelims = lang.strings.map { Array($0.utf16) }.sorted { $0.count > $1.count }
        multi = Set(lang.multilineStrings.map { Array($0.utf16) })
        lineComment = lang.lineComment.map { Array($0.utf16) }
        blockStart = lang.blockComment.map { Array($0.0.utf16) }
        blockEnd = lang.blockComment.map { Array($0.1.utf16) }
    }

    static func tokenize(_ lang: Language, _ text: [UInt16]) -> [Token] {
        var l = Lexer(lang: lang, text: text)
        l.run(0, text.count)
        return l.tokens
    }

    // MARK: Helpers

    private static let nl: UInt16 = 10, quote: UInt16 = 34, apos: UInt16 = 39, backslash: UInt16 = 92, slash: UInt16 = 47

    @inline(__always) private func at(_ i: Int) -> UInt16 { i < n ? s[i] : 0 }
    @inline(__always) private func isIdentStart(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127 }
    @inline(__always) private func isIdent(_ c: UInt16) -> Bool { isIdentStart(c) || (c >= 48 && c <= 57) }
    @inline(__always) private func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    @inline(__always) private func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 }

    private func matches(_ p: [UInt16], _ i: Int) -> Bool {
        guard i + p.count <= n else { return false }
        for k in 0..<p.count where s[i + k] != p[k] { return false }
        return true
    }

    private func find(_ p: [UInt16], from i: Int, limit: Int) -> Int? {
        var j = i
        while j + p.count <= limit {
            if s[j] == p[0], matches(p, j) { return j }
            j += 1
        }
        return nil
    }

    private func lineEnd(_ i: Int, _ limit: Int) -> Int {
        var j = i
        while j < limit && s[j] != Self.nl { j += 1 }
        return j
    }

    private mutating func add(_ start: Int, _ end: Int, _ kind: TokenKind) {
        if end > start { tokens.append(Token(start: Int32(start), length: Int32(end - start), kind: kind)) }
    }

    private func word(_ a: Int, _ b: Int) -> String { String(utf16CodeUnits: Array(s[a..<b]), count: b - a) }

    private func nextNonSpace(_ i: Int) -> UInt16 {
        var j = i
        while j < n && isSpace(s[j]) { j += 1 }
        return at(j)
    }

    private func prevNonSpace(_ i: Int) -> UInt16 {
        var j = i - 1
        while j >= 0 && isSpace(s[j]) { j -= 1 }
        return j >= 0 ? s[j] : 0
    }

    private func atLineStart(_ i: Int) -> Bool {
        var j = i - 1
        while j >= 0 && isSpace(s[j]) { j -= 1 }
        return j < 0 || s[j] == Self.nl
    }

    // MARK: Dispatch

    mutating func run(_ from: Int, _ to: Int) {
        switch lang.lexer {
        case .code: code(from, to)
        case .markup: markup(from, to)
        case .css: css(from, to)
        case .markdown: markdown(from, to)
        case .yaml: yaml(from, to)
        case .toml: toml(from, to)
        case .diff: diff(from, to)
        case .plain: break
        }
    }

    // MARK: Strings

    /// Scans a string starting at `i` with delimiter `d`; returns end index (exclusive).
    private mutating func string(_ i: Int, _ d: [UInt16], _ limit: Int, kind: TokenKind = .string) -> Int {
        let multiline = multi.contains(d) || d.count == 3
        var j = i + d.count
        let raw = d == [96] && lang.id == "go"
        while j < limit {
            let c = s[j]
            if c == Self.backslash && !raw {
                add(j, min(j + 2, limit), .escape)
                j += 2
                continue
            }
            if c == d[0] && matches(d, j) { j += d.count; break }
            if c == Self.nl && !multiline { break }
            j += 1
        }
        j = min(j, limit)
        // Re-emit as one string token with escapes layered on top (escapes added first, so sort later).
        add(i, j, kind)
        return j
    }

    // MARK: Code

    private mutating func code(_ from: Int, _ to: Int) {
        var i = from
        let attr = lang.attributePrefix.compactMap { $0.utf16.first }
        let varPrefix = lang.variablePrefix?.utf16.first
        while i < to {
            let c = s[i]
            if isSpace(c) || c == Self.nl { i += 1; continue }

            if let bs = blockStart, c == bs[0], matches(bs, i), let be = blockEnd {
                let end = find(be, from: i + bs.count, limit: to).map { $0 + be.count } ?? to
                add(i, end, .comment); i = end; continue
            }
            if let lc = lineComment, c == lc[0], matches(lc, i) {
                // "#" comments vs "#[attr]" / "#if" handled by language tables (Rust uses //).
                let end = lineEnd(i, to)
                add(i, end, .comment); i = end; continue
            }
            if lang.preprocessor && c == 35 && atLineStart(i) {
                var end = lineEnd(i, to)
                while end > i && end < to && s[end - 1] == Self.backslash { end = lineEnd(end + 1, to) }
                // Keep <header> / "header" coloured as strings.
                add(i, end, .macro)
                var k = i
                while k < end { if s[k] == 60 || s[k] == Self.quote, let e = closing(s[k] == 60 ? 62 : Self.quote, k + 1, end) { add(k, e, .string); k = e } else { k += 1 } }
                i = end; continue
            }
            if c == Self.quote || c == Self.apos || c == 96 {
                if c == Self.apos && lang.charLiterals {
                    // Rust lifetimes / generics: 'a without a closing quote nearby.
                    if let e = closing(Self.apos, i + 1, min(to, i + 12)), e - i <= 10 || at(i + 1) == Self.backslash {
                        add(i, e, .string); i = e; continue
                    }
                    var e = i + 1
                    while e < to && isIdent(s[e]) { e += 1 }
                    add(i, e, .constant); i = max(e, i + 1); continue
                }
                if let d = stringDelims.first(where: { $0[0] == c && matches($0, i) }) {
                    let end = string(i, d, to)
                    if lang.id == "json", nextNonSpace(end) == 58 { retag(from: i, to: end, .property) }
                    i = end; continue
                }
            }
            if lang.id == "nix" || lang.id == "ruby", c == 39, matches([39, 39], i) {
                i = string(i, [39, 39], to); continue
            }
            if isDigit(c) || (c == 46 && isDigit(at(i + 1)) && !isIdent(at(i - 1))) {
                var j = i + 1
                while j < to {
                    let d = s[j]
                    if isIdent(d) { j += 1; continue }
                    if d == 46 && at(j + 1) != 46 && isDigit(at(j + 1)) { j += 1; continue }
                    if (d == 43 || d == 45) && (s[j - 1] == 101 || s[j - 1] == 69) && !(s[i] == 48 && (at(i + 1) == 120 || at(i + 1) == 88)) { j += 1; continue }
                    break
                }
                add(i, j, .number); i = j; continue
            }
            if let vp = varPrefix, c == vp {
                var j = i + 1
                if at(j) == 123 { // ${...}
                    j = closing(125, j + 1, to) ?? lineEnd(j, to)
                } else if at(j) == 40 { // $(...) — leave the command itself uncoloured
                    add(i, i + 2, .variable); i += 2; continue
                } else {
                    while j < to && (isIdent(s[j]) || (j == i + 1 && (s[j] == 64 || s[j] == 35 || s[j] == 63 || s[j] == 33 || s[j] == 42))) { j += 1 }
                }
                add(i, j, .property); i = max(j, i + 1); continue
            }
            if attr.contains(c) && (isIdentStart(at(i + 1)) || at(i + 1) == 91 || (c == 58 && at(i + 1) == 58 && false)) {
                if lang.id == "ruby" && c == 58 && (prevNonSpace(i) == 58 || isIdent(at(i - 1))) { i += 1; continue }
                var j = i + 1
                if at(j) == 91 { j = closing(93, j + 1, to) ?? lineEnd(j, to) } // #[derive(...)]
                else { while j < to && (isIdent(s[j]) || s[j] == 46) { j += 1 } }
                add(i, j, c == 58 ? .constant : .attribute); i = j; continue
            }
            if isIdentStart(c) {
                var j = i + 1
                while j < to && isIdent(s[j]) { j += 1 }
                if lang.id == "ruby" || lang.id == "elixir", j < to, s[j] == 63 || s[j] == 33 { j += 1 }
                // Python-style string prefixes: f"…", rb'…'
                if j - i <= 2, j < to, s[j] == Self.quote || s[j] == Self.apos,
                   word(i, j).allSatisfy({ lang.stringPrefixes.contains($0) }) {
                    if let d = stringDelims.first(where: { $0[0] == s[j] && matches($0, j) }) {
                        let end = string(j, d, to); add(i, j, .keyword); i = end; continue
                    }
                }
                let w = word(i, j)
                let key = lang.caseInsensitive ? w.lowercased() : w
                let prev = prevNonSpace(i)
                let kind: TokenKind?
                if prev == 46 && !kw.contains(key) {
                    kind = nextNonSpace(j) == 40 ? .function : .property
                } else if kw.contains(key) {
                    kind = .keyword
                } else if consts.contains(key) {
                    kind = .constant
                } else if types.contains(key) {
                    kind = .type
                } else if nextNonSpace(j) == 40 || (nextNonSpace(j) == 33 && lang.id == "rust") {
                    kind = builtins.contains(w) ? .macro : .function
                } else if builtins.contains(w) {
                    kind = .macro
                } else if lang.capitalizedTypes, let f = s.indices.contains(i) ? s[i] : nil, f >= 65 && f <= 90 {
                    // ALL_CAPS → constant, CamelCase → type
                    kind = w.count > 1 && w == w.uppercased() ? .constant : .type
                } else {
                    kind = nil
                }
                if let kind { add(i, j, kind) }
                i = j; continue
            }
            if c == Self.slash, (lang.id == "javascript" || lang.id == "typescript" || lang.id.hasSuffix("react")), isRegexStart(i) {
                if let e = regexEnd(i + 1, to) { add(i, e, .regex); i = e; continue }
            }
            i += 1
        }
    }

    private func closing(_ ch: UInt16, _ from: Int, _ limit: Int) -> Int? {
        var j = from
        while j < limit {
            if s[j] == Self.backslash { j += 2; continue }
            if s[j] == ch { return j + 1 }
            if s[j] == Self.nl && ch != 125 && ch != 93 { return nil }
            j += 1
        }
        return nil
    }

    private func isRegexStart(_ i: Int) -> Bool {
        let p = prevNonSpace(i)
        let next = at(i + 1)
        if next == Self.slash || next == 42 || next == 32 { return false }
        // After an operator / opening punctuation a slash starts a regex literal.
        return p == 0 || p == 40 || p == 44 || p == 61 || p == 58 || p == 91 || p == 33 || p == 38 || p == 124 || p == 63 || p == 123 || p == 59 || p == Self.nl
    }

    private func regexEnd(_ from: Int, _ limit: Int) -> Int? {
        var j = from, inClass = false
        while j < limit {
            let c = s[j]
            if c == Self.nl { return nil }
            if c == Self.backslash { j += 2; continue }
            if c == 91 { inClass = true } else if c == 93 { inClass = false }
            else if c == Self.slash && !inClass {
                j += 1
                while j < limit && isIdentStart(s[j]) { j += 1 }
                return j
            }
            j += 1
        }
        return nil
    }

    private mutating func retag(from a: Int, to b: Int, _ kind: TokenKind) {
        for k in tokens.indices.reversed() {
            if Int(tokens[k].start) == a && Int(tokens[k].start + tokens[k].length) == b { tokens[k].kind = kind; return }
            if Int(tokens[k].start) < a { return }
        }
    }

    // MARK: Markup (HTML / XML / Vue / Svelte)

    private mutating func markup(_ from: Int, _ to: Int) {
        var i = from
        while i < to {
            let c = s[i]
            if c == 60 { // <
                if matches(Array("<!--".utf16), i) {
                    let end = find(Array("-->".utf16), from: i + 4, limit: to).map { $0 + 3 } ?? to
                    add(i, end, .comment); i = end; continue
                }
                if matches(Array("<![CDATA[".utf16), i) {
                    let end = find(Array("]]>".utf16), from: i, limit: to).map { $0 + 3 } ?? to
                    add(i, end, .string); i = end; continue
                }
                var j = i + 1
                if at(j) == 47 || at(j) == 33 || at(j) == 63 { j += 1 }
                let nameStart = j
                while j < to && (isIdent(s[j]) || s[j] == 45 || s[j] == 58 || s[j] == 46) { j += 1 }
                guard j > nameStart else { i += 1; continue }
                add(i, j, .tag)
                let tagName = word(nameStart, j).lowercased()
                // attributes
                while j < to && s[j] != 62 {
                    let a = s[j]
                    if a == Self.quote || a == Self.apos {
                        let e = closing(a, j + 1, to).map { $0 } ?? to
                        add(j, e, .string); j = e; continue
                    }
                    if isIdentStart(a) || a == 64 || a == 58 || a == 118 {
                        let st = j
                        while j < to && (isIdent(s[j]) || s[j] == 45 || s[j] == 58 || s[j] == 64 || s[j] == 46) { j += 1 }
                        add(st, j, .attribute); continue
                    }
                    if a == 123 { // {expr} in JSX / Svelte
                        let e = closing(125, j + 1, to) ?? to
                        add(j, e, .variable); j = e; continue
                    }
                    j += 1
                }
                let close = min(j + 1, to)
                add(j, close, .tag)
                i = close
                // Embedded <script> / <style>
                if (tagName == "script" || tagName == "style") && s[nameStart - 1] != 47 {
                    let endTag = Array("</\(tagName)".utf16)
                    let end = find(endTag, from: i, limit: to) ?? to
                    var sub = Lexer(lang: tagName == "script" ? Language.byID("typescript") : Language.byID("css"), text: s)
                    sub.run(i, end)
                    tokens += sub.tokens
                    i = end
                }
                continue
            }
            if c == 38 { // &entity;
                var j = i + 1
                while j < to && j - i < 10 && (isIdent(s[j]) || s[j] == 35) { j += 1 }
                if at(j) == 59 { add(i, j + 1, .escape); i = j + 1; continue }
            }
            if c == 123 && at(i + 1) == 123 { // {{ mustache }}
                let end = find([125, 125], from: i, limit: to).map { $0 + 2 } ?? to
                add(i, end, .variable); i = end; continue
            }
            i += 1
        }
    }

    // MARK: CSS / SCSS / Less

    private mutating func css(_ from: Int, _ to: Int) {
        var i = from, depth = 0
        while i < to {
            let c = s[i]
            if c == Self.slash && at(i + 1) == 42 {
                let end = find([42, 47], from: i + 2, limit: to).map { $0 + 2 } ?? to
                add(i, end, .comment); i = end; continue
            }
            if c == Self.slash && at(i + 1) == Self.slash && lang.id != "css" {
                let end = lineEnd(i, to); add(i, end, .comment); i = end; continue
            }
            if c == Self.quote || c == Self.apos { i = string(i, [c], to); continue }
            if c == 123 { depth += 1; i += 1; continue }
            if c == 125 { depth = max(0, depth - 1); i += 1; continue }
            if c == 64 { // @media, @include
                var j = i + 1
                while j < to && (isIdent(s[j]) || s[j] == 45) { j += 1 }
                add(i, j, .keyword); i = j; continue
            }
            if c == 36 && lang.id != "css" { // $var
                var j = i + 1
                while j < to && (isIdent(s[j]) || s[j] == 45) { j += 1 }
                add(i, j, .variable); i = j; continue
            }
            if c == 35 && depth > 0 { // #fff
                var j = i + 1
                while j < to && isIdent(s[j]) { j += 1 }
                add(i, j, .number); i = j; continue
            }
            if c == 33 && matches(Array("!important".utf16), i) { add(i, i + 10, .keyword); i += 10; continue }
            if isDigit(c) || (c == 46 && isDigit(at(i + 1))) || (c == 45 && isDigit(at(i + 1))) {
                var j = i + 1
                while j < to && (isIdent(s[j]) || s[j] == 46 || s[j] == 37) { j += 1 }
                add(i, j, .number); i = j; continue
            }
            if isIdentStart(c) || c == 45 || ((c == 46 || c == 35 || c == 58 || c == 38) && depth == 0) {
                var j = i + 1
                while j < to && (isIdent(s[j]) || s[j] == 45) { j += 1 }
                let next = nextNonSpace(j)
                let kind: TokenKind
                if next == 40 { kind = .function }
                else if depth > 0 && next == 58 && !(c == 58) { kind = .property }
                else if depth > 0 { kind = .constant }
                else if c == 46 { kind = .type }
                else if c == 35 { kind = .constant }
                else if c == 58 || c == 38 { kind = .keyword }
                else { kind = .tag }
                add(i, j, kind); i = j; continue
            }
            i += 1
        }
    }

    // MARK: Markdown

    private mutating func markdown(_ from: Int, _ to: Int) {
        var i = from
        while i < to {
            let lineStart = i
            let end = lineEnd(i, to)
            var j = i
            while j < end && isSpace(s[j]) { j += 1 }
            if matches([96, 96, 96], j) || matches([126, 126, 126], j) {
                let fence = Array(s[j..<j + 3])
                var langEnd = j + 3
                while langEnd < end && !isSpace(s[langEnd]) { langEnd += 1 }
                let tag = word(j + 3, langEnd)
                var close = end + 1
                var found = to
                while close < to {
                    let le = lineEnd(close, to)
                    var k = close
                    while k < le && isSpace(s[k]) { k += 1 }
                    if matches(fence, k) { found = le; break }
                    close = le + 1
                }
                add(j, end, .comment)
                let bodyStart = min(end + 1, to), bodyEnd = min(max(close, bodyStart), to)
                let inner = Language.all.first { $0.id == tag.lowercased() || $0.extensions.contains(tag.lowercased()) }
                if let inner, inner.lexer != .markdown {
                    var sub = Lexer(lang: inner, text: s); sub.run(bodyStart, bodyEnd); tokens += sub.tokens
                } else {
                    add(bodyStart, bodyEnd, .string)
                }
                add(bodyEnd, min(found, to), .comment)
                i = min(found + 1, to); continue
            }
            if at(j) == 35 { add(j, end, .heading); i = end + 1; continue }
            if at(j) == 62 { add(j, end, .comment); i = end + 1; continue }
            if (at(j) == 45 || at(j) == 42 || at(j) == 43) && at(j + 1) == 32 { add(j, j + 1, .keyword) }
            if isDigit(at(j)) {
                var k = j
                while k < end && isDigit(s[k]) { k += 1 }
                if at(k) == 46 && at(k + 1) == 32 { add(j, k + 1, .keyword) }
            }
            inlineMarkdown(lineStart, end)
            i = end + 1
        }
    }

    private mutating func inlineMarkdown(_ from: Int, _ to: Int) {
        var i = from
        while i < to {
            let c = s[i]
            if c == 96, let e = closing(96, i + 1, to) { add(i, e, .string); i = e; continue }
            if (c == 42 || c == 95) && at(i + 1) == c {
                if let e = find([c, c], from: i + 2, limit: to) { add(i, e + 2, .keyword); i = e + 2; continue }
            }
            if c == 91, let close = closing(93, i + 1, to), at(close) == 40, let p = closing(41, close + 1, to) {
                add(i, close, .link); add(close, p, .string); i = p; continue
            }
            i += 1
        }
    }

    // MARK: YAML / TOML / INI

    private mutating func yaml(_ from: Int, _ to: Int) {
        var i = from
        while i < to {
            let end = lineEnd(i, to)
            var j = i
            while j < end && isSpace(s[j]) { j += 1 }
            if at(j) == 45 && (at(j + 1) == 32 || j + 1 == end) { add(j, j + 1, .keyword); j += 2 }
            if at(j) == 35 { add(j, end, .comment); i = end + 1; continue }
            if matches([45, 45, 45], j) { add(j, end, .keyword); i = end + 1; continue }
            // key:
            var k = j
            if at(k) == Self.quote || at(k) == Self.apos { k = closing(at(k), k + 1, end) ?? end }
            else { while k < end && s[k] != 58 && s[k] != 35 { k += 1 } }
            if at(k) == 58 && (k + 1 == end || isSpace(at(k + 1))) && k > j {
                add(j, k, .property); j = k + 1
            }
            value(j, end)
            i = end + 1
        }
    }

    private mutating func toml(_ from: Int, _ to: Int) {
        var i = from
        while i < to {
            let end = lineEnd(i, to)
            var j = i
            while j < end && isSpace(s[j]) { j += 1 }
            if at(j) == 35 || at(j) == 59 { add(j, end, .comment); i = end + 1; continue }
            if at(j) == 91 { add(j, end, .heading); i = end + 1; continue }
            var k = j
            while k < end && s[k] != 61 && s[k] != 58 { k += 1 }
            if k < end, k > j {
                add(j, k, .property)
                value(k + 1, end)
            } else if lang.id == "properties" && j < end {
                add(j, end, .property)
            }
            i = end + 1
        }
    }

    /// Scalars on the right-hand side of YAML/TOML entries.
    private mutating func value(_ from: Int, _ end: Int) {
        var j = from
        while j < end {
            let c = s[j]
            if c == 35 && (j == from || isSpace(s[j - 1])) { add(j, end, .comment); return }
            if c == Self.quote || c == Self.apos {
                if let d = stringDelims.first(where: { $0[0] == c && matches($0, j) }) { j = string(j, d, multi.contains(d) ? n : end); continue }
                let e = closing(c, j + 1, end) ?? end; add(j, e, .string); j = e; continue
            }
            if isDigit(c) || (c == 45 && isDigit(at(j + 1))) {
                var e = j + 1
                while e < end && (isIdent(s[e]) || s[e] == 46 || s[e] == 58 || s[e] == 45) { e += 1 }
                add(j, e, .number); j = e; continue
            }
            if isIdentStart(c) {
                var e = j + 1
                while e < end && isIdent(s[e]) { e += 1 }
                if consts.contains(word(j, e).lowercased()) { add(j, e, .constant) }
                j = e; continue
            }
            if c == 38 || c == 42 || c == 33 { // anchors, aliases, tags
                var e = j + 1
                while e < end && !isSpace(s[e]) { e += 1 }
                add(j, e, .attribute); j = e; continue
            }
            j += 1
        }
    }

    // MARK: Diff

    private mutating func diff(_ from: Int, _ to: Int) {
        var i = from
        while i < to {
            let end = lineEnd(i, to)
            switch at(i) {
            case 43: add(i, end, matches([43, 43, 43], i) ? .heading : .string)
            case 45: add(i, end, matches([45, 45, 45], i) ? .heading : .keyword)
            case 64: add(i, end, .function)
            case 100 where matches(Array("diff ".utf16), i): add(i, end, .heading)
            default: break
            }
            i = end + 1
        }
    }
}
