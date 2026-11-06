import AppKit
import SwiftUI

// MARK: - HTTP client: `.http` / `.rest` files (the format VS Code's REST Client and JetBrains use). Requests are
// separated by `###`; `@name = value` defines variables used as {{name}}. Send one with the ▶ beside it or ⌃⌥↩.

struct HTTPRequestSpec: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var method: String
    var url: String
    var headers: [(String, String)]
    var body: String
    var line: Int                       // 1-based line of the request line
    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct HTTPResult {
    var status: Int
    var time: Double
    var headers: [(String, String)]
    var body: String
    var size: Int
    var error: String?
}

enum HTTPFile {
    static let methods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    /// Parses requests and variables. Variables: `@name = value`, plus {{$timestamp}}, {{$uuid}}, {{$randomInt}}.
    static func parse(_ text: String) -> (requests: [HTTPRequestSpec], vars: [String: String]) {
        var vars: [String: String] = [:]
        var out: [HTTPRequestSpec] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        var name = ""
        while i < lines.count {
            let l = lines[i].trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("###") { name = l.dropFirst(3).trimmingCharacters(in: .whitespaces); i += 1; continue }
            if l.hasPrefix("@"), let eq = l.firstIndex(of: "=") {
                vars[l[l.index(after: l.startIndex)..<eq].trimmingCharacters(in: .whitespaces)] = l[l.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                i += 1; continue
            }
            if l.isEmpty || l.hasPrefix("#") || l.hasPrefix("//") {
                if l.hasPrefix("# @name ") { name = String(l.dropFirst(8)) }
                i += 1; continue
            }
            // A request line: "METHOD url" or just "url" (GET).
            let parts = l.split(separator: " ", maxSplits: 2).map(String.init)
            var method = "GET", url = l
            if let f = parts.first, methods.contains(f.uppercased()), parts.count >= 2 { method = f.uppercased(); url = parts[1] }
            else if !(l.hasPrefix("http://") || l.hasPrefix("https://") || l.hasPrefix("{{")) { i += 1; continue }
            let start = i + 1
            i += 1
            var headers: [(String, String)] = []
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, !lines[i].hasPrefix("###") {
                let h = lines[i]
                if let c = h.firstIndex(of: ":") { headers.append((h[..<c].trimmingCharacters(in: .whitespaces), h[h.index(after: c)...].trimmingCharacters(in: .whitespaces))) }
                i += 1
            }
            var body: [String] = []
            if i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
            while i < lines.count, !lines[i].hasPrefix("###") { body.append(lines[i]); i += 1 }
            while let last = body.last, last.trimmingCharacters(in: .whitespaces).isEmpty { body.removeLast() }
            out.append(HTTPRequestSpec(name: name.isEmpty ? "\(method) \(url)" : name, method: method, url: url, headers: headers, body: body.joined(separator: "\n"), line: start))
            name = ""
        }
        return (out, vars)
    }

    static func substitute(_ s: String, _ vars: [String: String]) -> String {
        var t = s
        for _ in 0..<3 {                      // variables can refer to variables
            for (k, v) in vars { t = t.replacingOccurrences(of: "{{\(k)}}", with: v) }
        }
        t = t.replacingOccurrences(of: "{{$timestamp}}", with: String(Int(Date().timeIntervalSince1970)))
        t = t.replacingOccurrences(of: "{{$uuid}}", with: UUID().uuidString.lowercased())
        t = t.replacingOccurrences(of: "{{$randomInt}}", with: String(Int.random(in: 0..<1000)))
        return t
    }

    static func send(_ r: HTTPRequestSpec, vars: [String: String]) async -> HTTPResult {
        let urlString = substitute(r.url, vars)
        guard let url = URL(string: urlString) else { return HTTPResult(status: 0, time: 0, headers: [], body: "", size: 0, error: "Not a valid URL: \(urlString)") }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = r.method
        for (k, v) in r.headers { req.setValue(substitute(v, vars), forHTTPHeaderField: substitute(k, vars)) }
        if !r.body.isEmpty {
            let b = substitute(r.body, vars)
            // "< ./file.json" sends a file.
            req.httpBody = Data(b.utf8)
        }
        let t0 = Date()
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let h = resp as? HTTPURLResponse
            let headers = (h?.allHeaderFields ?? [:]).map { ("\($0.key)", "\($0.value)") }.sorted { $0.0 < $1.0 }
            return HTTPResult(status: h?.statusCode ?? 0, time: Date().timeIntervalSince(t0), headers: headers, body: pretty(data), size: data.count)
        } catch {
            return HTTPResult(status: 0, time: Date().timeIntervalSince(t0), headers: [], body: "", size: 0, error: error.localizedDescription)
        }
    }

    static func pretty(_ d: Data) -> String {
        if let o = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]),
           let p = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            return String(decoding: p, as: UTF8.self)
        }
        return String(decoding: d.prefix(2_000_000), as: UTF8.self)
    }
}

@MainActor
final class HTTPModel: ObservableObject {
    @Published var results: [UUID: HTTPResult] = [:]
    @Published var sending: Set<UUID> = []
    @Published var selected: UUID?

    func send(_ r: HTTPRequestSpec, vars: [String: String]) {
        sending.insert(r.id); selected = r.id
        Task {
            let res = await HTTPFile.send(r, vars: vars)
            results[r.id] = res; sending.remove(r.id)
        }
    }
}

struct HTTPPane: View {
    @ObservedObject var doc: EditorDocument
    @StateObject private var model = HTTPModel()
    @State private var parsed: (requests: [HTTPRequestSpec], vars: [String: String]) = ([], [:])
    @State private var showHeaders = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if parsed.requests.isEmpty {
                        Text("Write a request, e.g.\n\nGET https://api.github.com/repos/apple/swift\nAccept: application/json\n\n### separates requests; @token = abc defines {{token}}.")
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).padding(8)
                    }
                    ForEach(parsed.requests) { r in
                        row(r)
                    }
                }.padding(6)
            }
            .frame(maxHeight: 180)
            Divider()
            if let id = model.selected, let res = model.results[id] {
                HStack(spacing: 10) {
                    Text(res.error == nil ? "\(res.status) \(HTTPURLResponse.localizedString(forStatusCode: res.status).capitalized)" : "Failed")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(statusColor(res))
                    Text(String(format: "%.0f ms", res.time * 1000)).font(.caption).foregroundStyle(.secondary)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(res.size), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Headers", isOn: $showHeaders).toggleStyle(.button).controlSize(.small)
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(res.body, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy body")
                }.padding(.horizontal, 8).padding(.vertical, 5)
                Divider()
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let e = res.error { Text(e).foregroundStyle(.red) }
                        if showHeaders { Text(res.headers.map { "\($0.0): \($0.1)" }.joined(separator: "\n")).foregroundStyle(.secondary) }
                        Text(res.body.prefix(400_000))
                    }
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Send a request to see the response here.").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { parsed = HTTPFile.parse(doc.text) }
        .onReceive(NotificationCenter.default.publisher(for: NSTextStorage.didProcessEditingNotification, object: doc.storage)) { _ in parsed = HTTPFile.parse(doc.text) }
        .onReceive(NotificationCenter.default.publisher(for: .sendHTTPRequestAtCaret)) { n in
            guard (n.object as AnyObject?) === doc else { return }
            let line = doc.cursorLine
            if let r = parsed.requests.last(where: { $0.line - 1 <= line }) { model.send(r, vars: parsed.vars) }
        }
    }

    private func row(_ r: HTTPRequestSpec) -> some View {
        let sending = model.sending.contains(r.id)
        let title = r.name.hasPrefix(r.method) ? HTTPFile.substitute(r.url, parsed.vars) : r.name
        let res = model.results[r.id]
        let selected = model.selected == r.id
        return HStack(spacing: 6) {
            Button { model.send(r, vars: parsed.vars) } label: { sendIcon(sending) }
                .buttonStyle(.borderless).help("Send (⌃⌥↩ with the caret in the request)")
            Text(r.method).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(color(r.method))
            Text(title).font(.system(size: 12)).lineLimit(1)
            Spacer()
            if let res { Text(res.error == nil ? "\(res.status)" : "error").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(statusColor(res)) }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture {
            model.selected = r.id
            let off = doc.lineIndex.offset(line: r.line - 1, character: 0)
            doc.editor.select(NSRange(location: off, length: 0))
        }
    }

    @ViewBuilder private func sendIcon(_ sending: Bool) -> some View {
        if sending { ProgressView().controlSize(.mini) } else { Image(systemName: "play.fill").foregroundStyle(.green) }
    }

    private func color(_ m: String) -> Color { m == "GET" ? .blue : m == "POST" ? .green : m == "DELETE" ? .red : .orange }
    private func statusColor(_ r: HTTPResult) -> Color { r.error != nil ? .red : r.status < 300 ? .green : r.status < 400 ? .orange : .red }
}

extension Notification.Name { static let sendHTTPRequestAtCaret = Notification.Name("zide.sendHTTPRequest") }
