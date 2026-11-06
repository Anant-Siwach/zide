import AppKit

/// JetBrains-style live templates: type the abbreviation and press Tab (or pick it from completion).
struct LiveTemplate {
    let key: String
    let description: String
    let body: String     // $1, ${2:default}, $0 = final caret; \t = one indent level
}

enum LiveTemplates {
    static func templates(for lang: Language) -> [LiveTemplate] {
        switch lang.serverID ?? lang.id {
        case "swift": return swift
        case "python": return python
        case "typescript", "javascript": return js
        case "go": return go
        case "rust": return rust
        case "clangd", "c", "cpp", "objective-c": return c
        case "java": return java
        case "kotlin": return kotlin
        case "shellscript", "zsh": return shell
        case "html", "vue", "svelte": return html
        case "ruby": return ruby
        case "markdown": return markdown
        default: return []
        }
    }

    static let swift: [LiveTemplate] = [
        .init(key: "func", description: "function", body: "func ${1:name}(${2}) ${3:-> Void }{\n\t$0\n}"),
        .init(key: "iflet", description: "if let", body: "if let ${1:value} = ${2:optional} {\n\t$0\n}"),
        .init(key: "guard", description: "guard let … else", body: "guard let ${1:value} = ${2:optional} else { ${3:return} }\n$0"),
        .init(key: "forin", description: "for … in", body: "for ${1:item} in ${2:items} {\n\t$0\n}"),
        .init(key: "struct", description: "struct", body: "struct ${1:Name} {\n\t$0\n}"),
        .init(key: "class", description: "class", body: "final class ${1:Name} {\n\t$0\n}"),
        .init(key: "enum", description: "enum", body: "enum ${1:Name} {\n\tcase ${2:value}$0\n}"),
        .init(key: "switch", description: "switch", body: "switch ${1:value} {\ncase ${2:pattern}:\n\t$0\ndefault:\n\tbreak\n}"),
        .init(key: "do", description: "do / catch", body: "do {\n\ttry $1\n} catch {\n\t${2:print(error)}\n}$0"),
        .init(key: "view", description: "SwiftUI View", body: "struct ${1:ContentView}: View {\n\tvar body: some View {\n\t\t${2:Text(\"Hello\")}$0\n\t}\n}"),
        .init(key: "task", description: "Task { }", body: "Task {\n\t$0\n}"),
        .init(key: "main", description: "@main entry point", body: "@main\nstruct ${1:App} {\n\tstatic func main() {\n\t\t$0\n\t}\n}"),
    ]
    static let python: [LiveTemplate] = [
        .init(key: "def", description: "function", body: "def ${1:name}(${2}):\n\t${0:pass}"),
        .init(key: "class", description: "class", body: "class ${1:Name}:\n\tdef __init__(self${2}):\n\t\t${0:pass}"),
        .init(key: "main", description: "if __name__ == '__main__'", body: "if __name__ == \"__main__\":\n\t${0:main()}"),
        .init(key: "fori", description: "for i in range", body: "for ${1:i} in range(${2:n}):\n\t$0"),
        .init(key: "for", description: "for … in", body: "for ${1:item} in ${2:items}:\n\t$0"),
        .init(key: "try", description: "try / except", body: "try:\n\t$1\nexcept ${2:Exception} as e:\n\t${0:raise}"),
        .init(key: "with", description: "with open", body: "with open(${1:path}) as ${2:f}:\n\t$0"),
        .init(key: "dc", description: "dataclass", body: "@dataclass\nclass ${1:Name}:\n\t${2:field}: ${3:int}$0"),
    ]
    static let js: [LiveTemplate] = [
        .init(key: "log", description: "console.log", body: "console.log($1)$0"),
        .init(key: "fn", description: "function", body: "function ${1:name}(${2}) {\n\t$0\n}"),
        .init(key: "afn", description: "arrow function", body: "const ${1:name} = (${2}) => {\n\t$0\n}"),
        .init(key: "asf", description: "async function", body: "async function ${1:name}(${2}) {\n\t$0\n}"),
        .init(key: "fori", description: "for (let i…)", body: "for (let ${1:i} = 0; $1 < ${2:arr}.length; $1++) {\n\t$0\n}"),
        .init(key: "forof", description: "for … of", body: "for (const ${1:item} of ${2:items}) {\n\t$0\n}"),
        .init(key: "imp", description: "import", body: "import { $2 } from \"${1:module}\"$0"),
        .init(key: "try", description: "try / catch", body: "try {\n\t$1\n} catch (${2:err}) {\n\t$0\n}"),
        .init(key: "rfc", description: "React component", body: "export function ${1:Component}(${2:props}) {\n\treturn (\n\t\t<div>$0</div>\n\t)\n}"),
        .init(key: "ue", description: "useEffect", body: "useEffect(() => {\n\t$0\n}, [${1}])"),
        .init(key: "us", description: "useState", body: "const [${1:value}, set${2:Value}] = useState(${3})$0"),
    ]
    static let go: [LiveTemplate] = [
        .init(key: "iferr", description: "if err != nil", body: "if err != nil {\n\treturn ${1:err}\n}$0"),
        .init(key: "main", description: "package main", body: "package main\n\nimport \"fmt\"\n\nfunc main() {\n\t${0:fmt.Println(\"hello\")}\n}"),
        .init(key: "func", description: "function", body: "func ${1:name}(${2}) ${3:error} {\n\t$0\n}"),
        .init(key: "fori", description: "for i := …", body: "for ${1:i} := 0; $1 < ${2:n}; $1++ {\n\t$0\n}"),
        .init(key: "forr", description: "for range", body: "for ${1:_}, ${2:v} := range ${3:items} {\n\t$0\n}"),
        .init(key: "st", description: "struct", body: "type ${1:Name} struct {\n\t$0\n}"),
        .init(key: "test", description: "test function", body: "func Test${1:Name}(t *testing.T) {\n\t$0\n}"),
    ]
    static let rust: [LiveTemplate] = [
        .init(key: "fn", description: "function", body: "fn ${1:name}(${2}) ${3:-> () }{\n\t$0\n}"),
        .init(key: "main", description: "fn main", body: "fn main() {\n\t$0\n}"),
        .init(key: "test", description: "#[test]", body: "#[test]\nfn ${1:it_works}() {\n\t$0\n}"),
        .init(key: "match", description: "match", body: "match ${1:value} {\n\t${2:pattern} => $0,\n\t_ => {}\n}"),
        .init(key: "impl", description: "impl block", body: "impl ${1:Type} {\n\t$0\n}"),
        .init(key: "derive", description: "#[derive]", body: "#[derive(${1:Debug, Clone})]$0"),
    ]
    static let c: [LiveTemplate] = [
        .init(key: "main", description: "int main", body: "int main(int argc, char *argv[]) {\n\t$0\n\treturn 0;\n}"),
        .init(key: "fori", description: "for (int i…)", body: "for (int ${1:i} = 0; $1 < ${2:n}; $1++) {\n\t$0\n}"),
        .init(key: "inc", description: "#include <…>", body: "#include <${1:stdio.h}>$0"),
        .init(key: "incq", description: "#include \"…\"", body: "#include \"${1:header.h}\"$0"),
        .init(key: "st", description: "struct", body: "typedef struct {\n\t$0\n} ${1:Name};"),
    ]
    static let java: [LiveTemplate] = [
        .init(key: "psvm", description: "public static void main", body: "public static void main(String[] args) {\n\t$0\n}"),
        .init(key: "sout", description: "System.out.println", body: "System.out.println($1);$0"),
        .init(key: "fori", description: "for (int i…)", body: "for (int ${1:i} = 0; $1 < ${2:n}; $1++) {\n\t$0\n}"),
        .init(key: "iter", description: "for-each", body: "for (${1:var} ${2:item} : ${3:items}) {\n\t$0\n}"),
    ]
    static let kotlin: [LiveTemplate] = [
        .init(key: "main", description: "fun main", body: "fun main() {\n\t$0\n}"),
        .init(key: "fun", description: "function", body: "fun ${1:name}(${2}) {\n\t$0\n}"),
        .init(key: "sout", description: "println", body: "println($1)$0"),
    ]
    static let shell: [LiveTemplate] = [
        .init(key: "shebang", description: "#!/usr/bin/env bash", body: "#!/usr/bin/env bash\nset -euo pipefail\n\n$0"),
        .init(key: "if", description: "if … fi", body: "if [[ ${1:condition} ]]; then\n\t$0\nfi"),
        .init(key: "for", description: "for … done", body: "for ${1:item} in ${2:items}; do\n\t$0\ndone"),
        .init(key: "fn", description: "function", body: "${1:name}() {\n\t$0\n}"),
    ]
    static let html: [LiveTemplate] = [
        .init(key: "html5", description: "HTML document", body: "<!doctype html>\n<html lang=\"en\">\n<head>\n\t<meta charset=\"utf-8\">\n\t<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n\t<title>${1:Title}</title>\n</head>\n<body>\n\t$0\n</body>\n</html>"),
        .init(key: "div", description: "<div>", body: "<div class=\"$1\">$0</div>"),
        .init(key: "a", description: "<a href>", body: "<a href=\"$1\">$0</a>"),
        .init(key: "script", description: "<script>", body: "<script>\n\t$0\n</script>"),
    ]
    static let ruby: [LiveTemplate] = [
        .init(key: "def", description: "method", body: "def ${1:name}\n\t$0\nend"),
        .init(key: "class", description: "class", body: "class ${1:Name}\n\t$0\nend"),
        .init(key: "each", description: ".each do", body: "${1:items}.each do |${2:item}|\n\t$0\nend"),
    ]
    static let markdown: [LiveTemplate] = [
        .init(key: "code", description: "code block", body: "```${1:swift}\n$0\n```"),
        .init(key: "link", description: "link", body: "[${1:text}](${2:url})$0"),
        .init(key: "table", description: "table", body: "| ${1:A} | ${2:B} |\n| --- | --- |\n| $0 |  |"),
    ]
}

/// Parses snippet syntax ($1, ${1:default}, ${1|a,b|}, $0) into text plus ordered tab stops.
enum Snippet {
    static func parse(_ s: String) -> (text: String, stops: [NSRange]) {
        var out = ""
        var stops: [Int: [NSRange]] = [:]
        let chars = Array(s)
        var i = 0
        func utf16Len(_ str: String) -> Int { (str as NSString).length }
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count { out.append(chars[i + 1]); i += 2; continue }
            if c == "$", i + 1 < chars.count {
                if chars[i + 1] == "{" {
                    var j = i + 2, num = ""
                    while j < chars.count, chars[j].isNumber { num.append(chars[j]); j += 1 }
                    if let n = Int(num) {
                        var depth = 1, body = ""
                        var k = j
                        while k < chars.count {
                            if chars[k] == "{" { depth += 1 } else if chars[k] == "}" { depth -= 1; if depth == 0 { break } }
                            body.append(chars[k]); k += 1
                        }
                        var placeholder = ""
                        if body.hasPrefix(":") { placeholder = parse(String(body.dropFirst())).text }
                        else if body.hasPrefix("|") { placeholder = String(body.dropFirst().split(separator: "|").first?.split(separator: ",").first ?? "") }
                        let start = utf16Len(out)
                        out += placeholder
                        stops[n, default: []].append(NSRange(location: start, length: utf16Len(placeholder)))
                        i = k + 1
                        continue
                    }
                } else if chars[i + 1].isNumber {
                    var j = i + 1, num = ""
                    while j < chars.count, chars[j].isNumber { num.append(chars[j]); j += 1 }
                    let n = Int(num) ?? 0
                    stops[n, default: []].append(NSRange(location: utf16Len(out), length: 0))
                    i = j
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        // Order: 1, 2, 3 … then 0 (the final caret). Mirrored stops ($1 used twice) use the first occurrence.
        var ordered = stops.keys.filter { $0 > 0 }.sorted().compactMap { stops[$0]?.first }
        ordered.append(stops[0]?.first ?? NSRange(location: utf16Len(out), length: 0))
        return (out, ordered)
    }
}

extension CodeTextView {
    /// Inserts a snippet, re-indenting continuation lines to the current line and starting a tab-stop session.
    func insertSnippet(_ body: String, replacing range: NSRange) {
        let ns = string as NSString
        let line = ns.lineRange(for: NSRange(location: range.location, length: 0))
        let indent = String(ns.substring(with: NSRange(location: line.location, length: range.location - line.location)).prefix { $0 == " " || $0 == "\t" })
        let unit = Prefs.shared.indentUnit
        let normalized = body.replacingOccurrences(of: "\t", with: unit).replacingOccurrences(of: "\n", with: "\n" + indent)
        let (text, stops) = Snippet.parse(normalized)
        replace(range, with: text)
        let absolute = stops.map { NSRange(location: range.location + $0.location, length: $0.length) }
        snippetStops = Array(absolute.dropFirst())
        if let first = absolute.first { setSelectedRange(first) }
        if absolute.count <= 1 { snippetStops = [] }
    }

    /// Tab moves to the next tab stop of the active snippet. Returns false when there's none.
    func nextSnippetStop() -> Bool {
        guard !snippetStops.isEmpty else { return false }
        let next = snippetStops.removeFirst()
        setSelectedRange(next)
        return true
    }

    func adjustSnippetStops(_ range: NSRange, replacementLength: Int) {
        guard !snippetStops.isEmpty else { return }
        let delta = replacementLength - range.length
        snippetStops = snippetStops.map { s in
            if range.location > NSMaxRange(s) { return s }
            if NSMaxRange(range) <= s.location && !(range.location == s.location && range.length == 0 && s.length == 0) {
                return NSRange(location: s.location + delta, length: s.length)
            }
            // Typing inside a placeholder grows / shrinks it.
            return NSRange(location: s.location, length: max(0, s.length + delta))
        }
    }

    /// Expands a live template whose abbreviation sits right before the caret.
    func expandTemplateBeforeCaret() -> Bool {
        guard let c = controller, let lang = c.document?.language else { return false }
        let caret = selectedRange()
        guard caret.length == 0 else { return false }
        let word = c.wordRange(at: caret.location)
        guard word.length > 0, NSMaxRange(word) == caret.location else { return false }
        let key = (string as NSString).substring(with: word)
        guard let t = LiveTemplates.templates(for: lang).first(where: { $0.key == key }) else { return false }
        insertSnippet(t.body, replacing: word)
        return true
    }
}
