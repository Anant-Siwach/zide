import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Live preview for web files: the page renders beside the editor and refreshes as you type — including unsaved
// edits in its CSS and JS files, which are served straight from the editor buffers. Plus Markdown → HTML → PDF export.

/// Serves project files to the preview, preferring what's in the editor (unsaved changes included).
final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "zide-preview"
    let root: URL
    let buffer: (URL) -> String?
    init(root: URL, buffer: @escaping (URL) -> String?) { self.root = root; self.buffer = buffer }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let u = task.request.url else { return }
        let rel = u.path.removingPercentEncoding ?? u.path
        let file = root.appendingPathComponent(String(rel.drop { $0 == "/" })).standardizedFileURL
        let data: Data?
        if !file.path.hasPrefix(root.standardizedFileURL.path) { data = nil }
        else if let s = buffer(file) { data = Data(s.utf8) }
        else { data = try? Data(contentsOf: file) }
        guard let data else {
            task.didReceive(HTTPURLResponse(url: u, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            task.didReceive(Data("Not found".utf8)); task.didFinish(); return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(url: u, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": mime + (mime.hasPrefix("text/") || mime.contains("javascript") ? "; charset=utf-8" : "")])!)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

@MainActor
final class PreviewModel: NSObject, ObservableObject, WKScriptMessageHandler {
    unowned let workspace: Workspace
    @Published var page: URL?
    @Published var console: [String] = []
    let webView: WKWebView
    private var timer: Timer?
    private var observer: Any?

    init(workspace: Workspace) {
        self.workspace = workspace
        let cfg = WKWebViewConfiguration()
        let ws = workspace
        cfg.setURLSchemeHandler(PreviewSchemeHandler(root: workspace.root) { url in
            MainActor.assumeIsolated { ws.documents.first { $0.url.standardizedFileURL == url }?.text }
        }, forURLScheme: PreviewSchemeHandler.scheme)
        // Keep the scroll position across refreshes, and show console output and errors under the page.
        let js = """
        (function(){
          var y = sessionStorage.getItem('zideScroll'); if (y) window.addEventListener('load', function(){ window.scrollTo(0, +y); });
          window.addEventListener('scroll', function(){ sessionStorage.setItem('zideScroll', window.scrollY); });
          function send(k, a){ try { window.webkit.messageHandlers.zide.postMessage(k + ': ' + Array.prototype.map.call(a, function(x){ try { return typeof x === 'object' ? JSON.stringify(x) : String(x) } catch(e) { return String(x) } }).join(' ')); } catch(e) {} }
          ['log','warn','error','info'].forEach(function(k){ var o = console[k]; console[k] = function(){ send(k, arguments); o.apply(console, arguments); }; });
          window.addEventListener('error', function(e){ send('error', [e.message + ' (' + (e.filename||'').split('/').pop() + ':' + e.lineno + ')']); });
        })();
        """
        cfg.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        cfg.userContentController.add(self, name: "zide")
        observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let st = n.object as? NSTextStorage, self.workspace.documents.contains(where: { $0.storage === st }), self.workspace.livePreview else { return }
                self.timer?.invalidate()
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in MainActor.assumeIsolated { self.reload() } }
            }
        }
    }

    nonisolated func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        let s = "\(message.body)"
        Task { @MainActor in self.console.append(s); if self.console.count > 200 { self.console.removeFirst(self.console.count - 200) } }
    }

    /// The page to show for the file being edited: the HTML itself, or the HTML that the CSS/JS belongs to.
    func follow(_ doc: EditorDocument) {
        let ext = doc.url.pathExtension.lowercased()
        var target = page
        if ["html", "htm", "xhtml"].contains(ext) { target = doc.url }
        else if target == nil || !FileManager.default.fileExists(atPath: target!.path) {
            let dir = doc.url.deletingLastPathComponent()
            target = [dir, workspace.root, dir.deletingLastPathComponent()].lazy.map { $0.appendingPathComponent("index.html") }.first { FileManager.default.fileExists(atPath: $0.path) }
        }
        if target != page { page = target; console = []; load() }
    }

    func load() {
        guard let p = page else { webView.loadHTMLString("<p style='font:14px -apple-system;color:#888;padding:20px'>No HTML page to preview. Open an .html file, or add index.html next to this file.</p>", baseURL: nil); return }
        let rel = p.standardizedFileURL.path.dropFirst(workspace.root.standardizedFileURL.path.count)
        if let u = URL(string: "\(PreviewSchemeHandler.scheme)://project\(rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(rel))") { webView.load(URLRequest(url: u)) }
    }
    func reload() { console = []; webView.reload() }
}

struct LivePreviewView: NSViewRepresentable {
    let model: PreviewModel
    func makeNSView(context: Context) -> WKWebView { model.webView }
    func updateNSView(_ v: WKWebView, context: Context) {}
}

struct LivePreviewPane: View {
    @ObservedObject var model: PreviewModel
    let doc: EditorDocument

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "globe").foregroundStyle(.secondary)
                Text(model.page.map { model.workspace.relative($0) } ?? "No page").font(.system(size: 11.5)).lineLimit(1)
                Spacer()
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Reload")
                Button { if let p = model.page { NSWorkspace.shared.open(p) } } label: { Image(systemName: "safari") }.buttonStyle(.borderless).help("Open in browser").disabled(model.page == nil)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            Divider()
            LivePreviewView(model: model)
            if !model.console.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.console.enumerated()), id: \.offset) { _, l in
                            Text(l).font(.system(size: 11, design: .monospaced)).foregroundStyle(l.hasPrefix("error") ? Color.red : l.hasPrefix("warn") ? Color.orange : Color.secondary)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(6)
                }.frame(height: 90)
            }
        }
        .onAppear { model.follow(doc) }
        .onChange(of: doc.id) { _, _ in model.follow(doc) }
    }
}

// MARK: - Markdown → HTML → PDF

enum MarkdownHTML {
    static func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }

    static func inline(_ s: String) -> String {
        var t = esc(s)
        let rules: [(String, String)] = [
            (#"!\[([^\]]*)\]\(([^)\s]+)\)"#, "<img alt=\"$1\" src=\"$2\">"),
            (#"\[([^\]]+)\]\(([^)\s]+)\)"#, "<a href=\"$2\">$1</a>"),
            (#"`([^`]+)`"#, "<code>$1</code>"),
            (#"\*\*([^*]+)\*\*"#, "<strong>$1</strong>"),
            (#"__([^_]+)__"#, "<strong>$1</strong>"),
            (#"(?<![\w*])\*([^*\s][^*]*)\*(?!\w)"#, "<em>$1</em>"),
            (#"~~([^~]+)~~"#, "<del>$1</del>"),
        ]
        for (p, r) in rules { t = t.replacingOccurrences(of: p, with: r, options: .regularExpression) }
        return t
    }

    static func body(_ text: String) -> String {
        var html: [String] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        var chunk: [String] = []
        func flushChunk() {
            guard !chunk.isEmpty else { return }
            var listOpen: String?
            for b in MDBlock.parse(chunk.joined(separator: "\n")) {
                if case .bullet = b.kind {} else if let l = listOpen { html.append("</\(l)>"); listOpen = nil }
                switch b.kind {
                case .heading(let n): html.append("<h\(min(n, 6))>\(inline(b.text))</h\(min(n, 6))>")
                case .code: html.append("<pre><code>\(esc(b.text))</code></pre>")
                case .quote: html.append("<blockquote>\(inline(b.text))</blockquote>")
                case .rule: html.append("<hr>")
                case .paragraph: html.append("<p>\(inline(b.text))</p>")
                case .bullet(_, let marker):
                    let tag = marker.first?.isNumber == true ? "ol" : "ul"
                    if listOpen != tag { if let l = listOpen { html.append("</\(l)>") }; html.append("<\(tag)>"); listOpen = tag }
                    var item = inline(b.text)
                    if item.hasPrefix("[ ] ") { item = "☐ " + item.dropFirst(4) } else if item.lowercased().hasPrefix("[x] ") { item = "☑ " + item.dropFirst(4) }
                    html.append("<li>\(item)</li>")
                }
            }
            if let l = listOpen { html.append("</\(l)>") }
            chunk = []
        }
        // Tables: a header row, a |---| row, then rows.
        while i < lines.count {
            let l = lines[i].trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("|"), i + 1 < lines.count, lines[i + 1].trimmingCharacters(in: .whitespaces).range(of: #"^\|?\s*:?-{2,}"#, options: .regularExpression) != nil {
                flushChunk()
                func cells(_ s: String) -> [String] { s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) } }
                var t = "<table><thead><tr>" + cells(l).map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead><tbody>"
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    t += "<tr>" + cells(lines[i]).map { "<td>\(inline($0))</td>" }.joined() + "</tr>"; i += 1
                }
                html.append(t + "</tbody></table>")
                continue
            }
            chunk.append(lines[i]); i += 1
        }
        flushChunk()
        return html.joined(separator: "\n")
    }

    static func document(_ text: String, title: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(esc(title))</title><style>
        body{font:15px/1.6 -apple-system,Helvetica,sans-serif;color:#1d1d1f;max-width:760px;margin:40px auto;padding:0 24px}
        h1,h2{border-bottom:1px solid #e5e5e5;padding-bottom:.3em} code{font:13px ui-monospace,Menlo,monospace;background:#f3f3f3;padding:1px 4px;border-radius:4px}
        pre{background:#f6f8fa;padding:12px;border-radius:8px;overflow:auto} pre code{background:none;padding:0}
        blockquote{border-left:4px solid #ddd;margin:0;padding:0 14px;color:#555} table{border-collapse:collapse} th,td{border:1px solid #ddd;padding:6px 10px}
        img{max-width:100%} a{color:#0a66d8} @media print{body{margin:0}}
        </style></head><body>
        \(body(text))
        </body></html>
        """
    }
}

/// Prints a page in an off-screen web view to a paginated PDF.
@MainActor
final class PDFExporter: NSObject, WKNavigationDelegate {
    private static var running: [PDFExporter] = []
    private let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1000))
    private let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
    private let out: URL
    private let done: (Bool) -> Void

    init(out: URL, done: @escaping (Bool) -> Void) { self.out = out; self.done = done }

    static func export(html: String, baseURL: URL?, to url: URL, done: @escaping (Bool) -> Void) {
        let e = PDFExporter(out: url, done: done)
        running.append(e)
        e.window.contentView = e.web
        e.web.navigationDelegate = e
        e.web.loadHTMLString(html, baseURL: baseURL)
    }
    static func export(file: URL, to url: URL, done: @escaping (Bool) -> Void) {
        let e = PDFExporter(out: url, done: done)
        running.append(e)
        e.window.contentView = e.web
        e.web.navigationDelegate = e
        e.web.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
    }

    nonisolated func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))          // images and fonts
            let info = NSPrintInfo(dictionary: [:])
            info.paperSize = NSSize(width: 595, height: 842)
            info.topMargin = 40; info.bottomMargin = 40; info.leftMargin = 36; info.rightMargin = 36
            info.horizontalPagination = .fit; info.verticalPagination = .automatic
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out
            let op = web.printOperation(with: info)
            op.showsPrintPanel = false; op.showsProgressPanel = false
            op.view?.frame = web.bounds
            op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            // runModal returns at once; wait for the file.
            for _ in 0..<100 where (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 == 0 { try? await Task.sleep(for: .milliseconds(100)) }
            let success = ((try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
            done(success)
            Self.running.removeAll { $0 === self }
        }
    }
}

extension Workspace {
    /// Markdown or HTML → PDF next to the file (or where you choose).
    func exportPDF(_ doc: EditorDocument) {
        let isMD = doc.language.id == "markdown", isHTML = ["html", "htm", "xhtml"].contains(doc.url.pathExtension.lowercased())
        guard isMD || isHTML else { flash("PDF export works for Markdown and HTML files."); return }
        let p = NSSavePanel()
        p.nameFieldStringValue = doc.url.deletingPathExtension().lastPathComponent + ".pdf"
        p.directoryURL = doc.url.deletingLastPathComponent()
        p.allowedContentTypes = [.pdf]
        guard p.runModal() == .OK, let url = p.url else { return }
        let finish: (Bool) -> Void = { [weak self] ok in
            if ok { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { self?.flash("PDF export failed.") }
        }
        if isMD { PDFExporter.export(html: MarkdownHTML.document(doc.text, title: doc.url.lastPathComponent), baseURL: doc.url.deletingLastPathComponent(), to: url, done: finish) }
        else { save(doc); PDFExporter.export(file: doc.url, to: url, done: finish) }
    }
}
