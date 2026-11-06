import AppKit
import SwiftUI

/// `Zide --selftest <file> <completion-marker> <symbol>`: drives the real editor + language-server
/// pipeline without UI and prints a JSON report. Used to verify language support from the terminal.
@MainActor
enum SelfTest {
    static func run(_ args: [String]) {
        guard args.count >= 1 else { finish(["error": "usage: --selftest <file> [after-text] [symbol]"]); return }
        let file = URL(fileURLWithPath: args[0]).standardizedFileURL
        let marker = args.count > 1 ? args[1] : nil
        let symbol = args.count > 2 ? args[2] : nil
        let top = Shell.run("git", ["rev-parse", "--show-toplevel"], cwd: file.deletingLastPathComponent())
        let root = top.ok ? URL(fileURLWithPath: top.out.trimmingCharacters(in: .whitespacesAndNewlines)) : file.deletingLastPathComponent()
        let ws = Workspace(root: root)
        guard let doc = ws.open(file, focus: false) else { finish(["error": "cannot open"]); return }
        var report: JSON = ["language": doc.language.name, "root": root.path]
        let started = Date()
        let tokens = Lexer.tokenize(doc.language, Array(doc.text.utf16))
        report["lexerTokens"] = tokens.count
        report["lexerKinds"] = Dictionary(grouping: tokens, by: { "\($0.kind)" }).mapValues(\.count)

        Task { @MainActor in
            // Wait for the server.
            while Date().timeIntervalSince(started) < 60 {
                if case .ready = ws.lsp.status(for: doc.language) { break }
                if case .missing(let s) = ws.lsp.status(for: doc.language) { report["server"] = "missing: \(s.install)"; break }
                if case .failed(_, let m) = ws.lsp.status(for: doc.language) { report["server"] = "failed: \(m)"; break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if report["server"] == nil { report["server"] = "\(ws.lsp.status(for: doc.language))" }
            report["serverStartSeconds"] = Double(Int(Date().timeIntervalSince(started) * 10)) / 10
            guard ws.lsp.client(of: doc) != nil else { finish(report); return }

            // Diagnostics (servers publish after analysing; give them time).
            let diagStart = Date()
            while doc.diagnostics.isEmpty && Date().timeIntervalSince(diagStart) < 25 { try? await Task.sleep(nanoseconds: 300_000_000) }
            report["diagnostics"] = doc.diagnostics.map { "\($0.severity) L\($0.line + 1): \($0.message)" }

            let ns = doc.text as NSString
            if let marker {
                let r = ns.range(of: marker)
                if r.location != NSNotFound {
                    let offset = NSMaxRange(r)
                    let res = await ws.lsp.request("textDocument/completion", doc, offset: offset, extra: ["context": ["triggerKind": 1]])
                    let items = (res as? [JSON]) ?? ((res as? JSON)?["items"] as? [JSON]) ?? []
                    report["completionCount"] = items.count
                    report["completionSample"] = items.prefix(8).compactMap { $0["label"] as? String }
                }
            }
            if let symbol {
                let r = ns.range(of: symbol, options: .backwards)
                if r.location != NSNotFound {
                    let offset = r.location + 1
                    let hover = await ws.lsp.request("textDocument/hover", doc, offset: offset) as? JSON
                    report["hover"] = String(LSP.markdown(hover?["contents"]).prefix(200))
                    let def = LSP.locations(await ws.lsp.request("textDocument/definition", doc, offset: offset))
                    report["definition"] = def.map { "\($0.0.lastPathComponent):\((($0.1["start"] as? JSON)?["line"] as? Int ?? -1) + 1)" }
                    let refs = LSP.locations(await ws.lsp.request("textDocument/references", doc, offset: offset, extra: ["context": ["includeDeclaration": true]]))
                    report["references"] = refs.count
                    let syms = await ws.documentSymbols(doc)
                    report["documentSymbols"] = syms.map(\.name)
                }
            }
            finish(report)
        }
    }

    private static func finish(_ report: JSON) {
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        exit(0)
    }
}

/// `Zide --debugtest <file> <line> <expression>`: breakpoint → debug → inspect → step → finish.
@MainActor
enum DebugSelfTest {
    static func run(_ args: [String]) {
        let file = URL(fileURLWithPath: args[0]).standardizedFileURL
        let line = Int(args[1]) ?? 1
        let expr = args.count > 2 ? args[2] : nil
        let top = Shell.run("git", ["rev-parse", "--show-toplevel"], cwd: file.deletingLastPathComponent())
        let root = top.ok ? URL(fileURLWithPath: top.out.trimmingCharacters(in: .whitespacesAndNewlines)) : file.deletingLastPathComponent()
        let ws = Workspace(root: root)
        ws.open(file, focus: false)
        ws.runner.select(RunConfig.currentFile.name)
        if ws.debug.lines(for: file).contains(line) == false { ws.debug.toggleBreakpoint(file, line: line) }
        if let cond = ProcessInfo.processInfo.environment["ZIDE_BP_CONDITION"] { ws.debug.setCondition(file, line: line, condition: cond) }
        var report: JSON = [:]
        ws.debug.start()
        Task { @MainActor in
            let t0 = Date()
            var lastCount = 0
            while ws.debug.state != .stopped && ws.debug.state != .finished && Date().timeIntervalSince(t0) < 120 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let c = ws.debug.console
                if c.count > lastCount { for l in c[lastCount...] { FileHandle.standardError.write(Data("[\(l.kind)] \(l.text.prefix(300))\n".utf8)) }; lastCount = c.count }
                FileHandle.standardError.write(Data("state=\(ws.debug.state)\n".utf8))
            }
            @MainActor func step(_ m: String) { FileHandle.standardError.write(Data("STEP \(m) state=\(ws.debug.state)\n".utf8)) }
            step("after wait")
            report["stoppedAfterSeconds"] = Int(Date().timeIntervalSince(t0))
            report["state"] = "\(ws.debug.state)"
            report["reason"] = ws.debug.stopReason
            report["executionPoint"] = ws.debug.executionPoint.map { "\($0.url.lastPathComponent):\($0.line)" } ?? "none"
            report["frames"] = ws.debug.frames.prefix(4).map { "\($0.name) @\($0.url?.lastPathComponent ?? "?"):\($0.line)" }
            step("frames read")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            step("slept")
            report["scopes"] = ws.debug.scopes.map { s in "\(s.name): " + (s.children ?? []).prefix(6).map { "\($0.name)=\($0.value)" }.joined(separator: ", ") }
            if let expr {
                ws.debug.evaluate(expr)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            step("before step")
            ws.debug.stepOver()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            report["afterStepOver"] = ws.debug.executionPoint.map { "\($0.url.lastPathComponent):\($0.line)" } ?? "none"
            step("after step")
            ws.debug.toggleBreakpoint(file, line: line)
            ws.debug.resume()
            step("resumed")
            let t1 = Date()
            while ws.debug.state != .finished && Date().timeIntervalSince(t1) < 15 { try? await Task.sleep(nanoseconds: 200_000_000) }
            report["finalState"] = "\(ws.debug.state)"
            report["console"] = Array(ws.debug.console.map { "[\($0.kind)] \($0.text)" }.suffix(14))
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
            }
            exit(0)
        }
    }
}

/// `Zide --editortest <dir>`: exercises multi-cursor editing and split panes on a temp file.
@MainActor
enum EditorSelfTest {
    static func run(_ dir: String) {
        let root = URL(fileURLWithPath: dir)
        let file = root.appendingPathComponent("multi.swift")
        try? "let a = 1\nlet b = 2\nlet c = 3\nprint(a + b + c)\n".write(to: file, atomically: true, encoding: .utf8)
        let ws = Workspace(root: root)
        guard let doc = ws.open(file, focus: false) else { exit(1) }
        let tv = doc.editor.textView
        var r: JSON = [:]
        // Carets at the start of the first three lines, type a comment prefix.
        tv.setCursors([NSRange(location: 0, length: 0), NSRange(location: 10, length: 0), NSRange(location: 20, length: 0)])
        r["caretCount"] = tv.allCursors.count
        tv.insertText("// ", replacementRange: NSRange(location: NSNotFound, length: 0))
        r["afterInsert"] = doc.text
        tv.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        r["afterBackspace"] = doc.text
        tv.doCommand(by: #selector(NSResponder.moveToEndOfLine(_:)))
        tv.insertText(";", replacementRange: NSRange(location: NSNotFound, length: 0))
        r["afterEndOfLine"] = doc.text
        tv.undoManager?.undo()
        r["afterUndo"] = doc.text
        tv.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        r["afterEsc"] = tv.allCursors.count
        // Select all occurrences of "let" and replace.
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        tv.selectAllOccurrences(nil)
        r["occurrences"] = tv.allCursors.count
        tv.insertText("var", replacementRange: NSRange(location: NSNotFound, length: 0))
        r["afterReplaceAll"] = doc.text
        tv.clearExtraCursors()
        // Next occurrence (⌃G)
        tv.setSelectedRange(NSRange(location: (doc.text as NSString).range(of: "a").location, length: 0))
        tv.selectNextOccurrence(nil); tv.selectNextOccurrence(nil)
        r["nextOccurrenceCarets"] = tv.allCursors.map { "\($0.location):\($0.length)" }
        tv.clearExtraCursors()
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        tv.addCaretBelow(nil); tv.addCaretBelow(nil)
        r["caretBelow"] = tv.allCursors.map(\.location)
        tv.clearExtraCursors()
        // Split panes share text.
        ws.splitRight()
        r["panes"] = ws.panes.count
        let right = doc.editor(pane: 1)
        r["sameStorage"] = right.textView.textStorage === tv.textStorage
        right.textView.setSelectedRange(NSRange(location: 0, length: 0))
        right.textView.insertText("/* hi */ ", replacementRange: NSRange(location: NSNotFound, length: 0))
        r["leftSeesRightEdit"] = tv.string.hasPrefix("/* hi */")
        ws.moveToOtherSplit()
        r["afterMovePanes"] = ws.panes.count
        ws.splitRight()
        ws.unsplit()
        r["afterUnsplit"] = ws.panes.count
        r["docsOpen"] = ws.documents.count
        try? FileManager.default.removeItem(at: file)
        if let d = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) { FileHandle.standardOutput.write(d); print() }
        exit(0)
    }
}

/// `Zide --editortest2 <dir>`: folding, live templates + tab stops, path completion, inlay hints.
@MainActor
enum EditorSelfTest2 {
    static func run(_ dir: String) {
        let root = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root.appendingPathComponent("assets/logo.png").path, contents: Data())
        FileManager.default.createFile(atPath: root.appendingPathComponent("assets/style.css").path, contents: Data())
        let swiftFile = root.appendingPathComponent("fold.swift")
        try? "func compute() {\n    let values = [1, 2, 3]\n    let total = values.reduce(0, +)\n    print(total)\n}\n\nstruct Box {\n    var size = 1\n}\n".write(to: swiftFile, atomically: true, encoding: .utf8)
        let jsFile = root.appendingPathComponent("paths.js")
        try? "const img = \"./assets/\"\n".write(to: jsFile, atomically: true, encoding: .utf8)
        let ws = Workspace(root: root)
        var r: JSON = [:]
        Task { @MainActor in
            guard let doc = ws.open(swiftFile, focus: false) else { exit(1) }
            let ed = doc.editor
            try? await Task.sleep(nanoseconds: 500_000_000)
            r["foldRegionLines"] = ed.foldRegions.keys.sorted().map { $0 + 1 }
            let before = ed.layoutManager.usedRect(for: ed.container).height
            ed.toggleFold(line: 0)
            ed.layoutManager.ensureLayout(for: ed.container)
            let after = ed.layoutManager.usedRect(for: ed.container).height
            r["foldedLine1"] = ed.isFolded(line: 0)
            r["heightBeforeAfter"] = "\(Int(before)) → \(Int(after))"
            r["textUnchanged"] = doc.text.hasPrefix("func compute() {\n    let values")
            ed.foldAll()
            r["foldAllCount"] = ed.folds.count
            ed.unfoldAll()
            r["afterUnfoldAll"] = ed.folds.count

            // Live template: "forin" + Tab
            let tv = ed.textView
            let end = doc.storage.length
            tv.setSelectedRange(NSRange(location: end, length: 0))
            tv.insertText("forin", replacementRange: NSRange(location: NSNotFound, length: 0))
            ed.completion.hide()
            tv.insertTab(nil)
            let ns = tv.string as NSString
            r["templateExpanded"] = ns.substring(from: end)
            r["firstStopSelected"] = ns.substring(with: tv.selectedRange())
            tv.insertText("n", replacementRange: NSRange(location: NSNotFound, length: 0))
            tv.insertTab(nil)
            r["secondStopSelected"] = (tv.string as NSString).substring(with: tv.selectedRange())
            tv.insertText("numbers", replacementRange: NSRange(location: NSNotFound, length: 0))
            tv.insertTab(nil)
            r["afterTemplate"] = (tv.string as NSString).substring(from: end)

            // Inlay hints (sourcekit-lsp)
            let t0 = Date()
            while ws.lsp.client(of: doc) == nil && Date().timeIntervalSince(t0) < 20 { try? await Task.sleep(nanoseconds: 300_000_000) }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            doc.refreshInlayHints()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            var hints: [String] = []
            doc.storage.enumerateAttribute(.zideInlayHint, in: NSRange(location: 0, length: doc.storage.length)) { v, _, _ in if let s = v as? String { hints.append(s) } }
            r["inlayHints"] = hints

            // Path completion in a JS string
            if let js = ws.open(jsFile, focus: false) {
                let jed = js.editor
                try? await Task.sleep(nanoseconds: 400_000_000)
                let caret = (js.text as NSString).range(of: "assets/").location + 7
                jed.textView.setSelectedRange(NSRange(location: caret, length: 0))
                jed.completion.trigger(manual: true)
                try? await Task.sleep(nanoseconds: 500_000_000)
                r["pathCompletions"] = jed.completion.items.map(\.label)
            }
            try? FileManager.default.removeItem(at: swiftFile)
            try? FileManager.default.removeItem(at: jsFile)
            if let d = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) { FileHandle.standardOutput.write(d); print() }
            exit(0)
        }
    }
}

/// `Zide --uishot <file-or-folder> <out.png> [seconds]`: opens a path the way a double-click does, reports how long
/// until the window is on screen, waits, and saves the window as a PNG (for visual checks).
@MainActor
enum UIShot {
    static let started = Date()

    static func run(_ args: [String]) {
        let target = URL(fileURLWithPath: args[0]), out = URL(fileURLWithPath: args[1])
        let delay = args.count > 2 ? Double(args[2]) ?? 1.5 : 1.5
        AppDelegate.quiet = true
        AppDelegate.shared.application(NSApp, open: [target])
        let env = ProcessInfo.processInfo.environment
        if env["ZIDE_CLIPTRACE"] != nil {
            for t in [0.0, 0.1, 0.3, 0.6, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated {
                    if let d = AppDelegate.shared.controllers.last?.workspace.active { let c = d.primaryEditor.scrollView.contentView; print("t=\(t) clip bounds x \(c.bounds.minX) insets \(c.contentInsets.left) ruler \(d.primaryEditor.scrollView.verticalRulerView?.ruleThickness ?? -1)") }
                } }
            }
        }
        if env["ZIDE_REPLACESHOT"] != nil {
            let f1 = URL(fileURLWithPath: "/tmp/src/player.ts"), f2 = URL(fileURLWithPath: "/tmp/src/round.ts")
            let items = [ReplacePreviewItem(file: f1, line: 12, before: "const rating = player.elo", after: "const rating = player.fideRating", edit: (NSRange(), "")),
                         ReplacePreviewItem(file: f1, line: 40, before: "if (p.elo > 2000) titled = true", after: "if (p.fideRating > 2000) titled = true", edit: (NSRange(), "")),
                         ReplacePreviewItem(file: f2, line: 7, before: "sort((a, b) => b.elo - a.elo)", after: "sort((a, b) => b.fideRating - a.fideRating)", edit: (NSRange(), ""))]
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
            w.title = "Replace Preview"
            w.contentView = NSHostingView(rootView: ReplacePreviewView(model: ReplacePreviewModel(items: items, title: "Replace “elo” with “fideRating” in 2 file(s)")))
            w.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated {
                let v = w.contentView!, rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: env["ZIDE_REPLACESHOT"]!))
            } }
        }
        if env["ZIDE_ZEN"] != nil { AppDelegate.shared.controllers.last?.workspace.zen = true }
        if let line = env["ZIDE_SCROLL"].flatMap(Int.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated {
                    guard let d = AppDelegate.shared.controllers.last?.workspace.active else { return }
                    let tv = d.primaryEditor.textView
                    let loc = d.lineIndex.starts[min(line, d.lineIndex.lineCount - 1)]
                    let r = tv.layoutManager!.lineFragmentRect(forGlyphAt: tv.layoutManager!.glyphIndexForCharacter(at: loc), effectiveRange: nil)
                    let clip = d.primaryEditor.scrollView.contentView
                    clip.scroll(to: NSPoint(x: clip.bounds.minX, y: r.minY - clip.contentInsets.top))
                    d.primaryEditor.scrollView.reflectScrolledClipView(clip)
                    print("clip x \(clip.frame.minX) bounds x \(clip.bounds.minX) ruler \(d.primaryEditor.scrollView.verticalRulerView?.ruleThickness ?? -1) sticky x \(d.primaryEditor.stickyView?.frame.minX ?? -1)")
                }
            }
        }
        if env["ZIDE_FOLLOW"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    guard let d = AppDelegate.shared.controllers.last?.workspace.active else { return }
                    d.primaryEditor.textView.setSelectedRange(NSRange(location: d.storage.length, length: 0))
                    let h = try! FileHandle(forWritingTo: target); h.seekToEndOfFile(); h.write("NEW LINE APPENDED\n".data(using: .utf8)!); try? h.close()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        MainActor.assumeIsolated {
                            let caret = d.primaryEditor.textView.selectedRange().location
                            print("follow: file reloaded \(d.storage.string.hasSuffix("NEW LINE APPENDED\n")), caret at end \(caret == d.storage.length)")
                        }
                    }
                }
            }
        }
        print(String(format: "window open %.0f ms after launch", Date().timeIntervalSince(started) * 1000))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }), let v = w.contentView,
                      let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { print("no window"); exit(1) }
                v.cacheDisplay(in: v.bounds, to: rep)
                let img = NSImage(size: v.bounds.size)
                img.lockFocus()
                w.backgroundColor.setFill(); NSRect(origin: .zero, size: v.bounds.size).fill()
                NSImage(cgImage: rep.cgImage!, size: v.bounds.size).draw(in: NSRect(origin: .zero, size: v.bounds.size))
                img.unlockFocus()
                if let t = img.tiffRepresentation, let r = NSBitmapImageRep(data: t) { try? r.representation(using: .png, properties: [:])?.write(to: out) }
                print("saved \(out.lastPathComponent) (\(Int(w.frame.width))×\(Int(w.frame.height)))")
                exit(0)
            }
        }
    }
}

/// `Zide --texttoolstest <dir>`: indentation detection and the Transform menu (with undo).
@MainActor
enum TextToolsTest {
    static func run(_ dir: String) {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print((ok ? "  ok   " : "  FAIL ") + what); if !ok { failures += 1 } }
        func doc(_ name: String, _ text: String) -> EditorDocument {
            let u = URL(fileURLWithPath: dir).appendingPathComponent(name)
            try! text.write(to: u, atomically: true, encoding: .utf8)
            return EditorDocument(url: u)
        }
        let two = doc("a.js", "function f() {\n  if (x) {\n    y()\n  }\n  return 1\n}\nfunction g() {\n  a()\n  b()\n}\n")
        check(two.insertSpaces && two.tabWidth == 2, "2-space JS → \(two.insertSpaces ? "\(two.tabWidth) spaces" : "tab")")
        let four = doc("b.py", "def f():\n    if x:\n        y()\n    return 1\n\ndef g():\n    a()\n    b()\n")
        check(four.insertSpaces && four.tabWidth == 4, "4-space Python → \(four.insertSpaces ? "\(four.tabWidth) spaces" : "tab")")
        let tabs = doc("c.go", "func f() {\n\tif x {\n\t\ty()\n\t}\n\treturn\n}\nfunc g() {\n\ta()\n\tb()\n}\n")
        check(!tabs.insertSpaces, "tab-indented Go → \(tabs.insertSpaces ? "spaces" : "tab")")
        let none = doc("d.txt", "hello\nworld\n")
        check(none.detectedIndent == nil, "plain note → uses the setting")

        let d = doc("e.txt", "pear\napple\nBanana\napple\n\n  cherry  \n")
        let tv = d.primaryEditor.textView
        let undo = UndoManager()
        tv.allowsUndo = true
        func run(_ sel: Selector, _ text: String? = nil) -> String {
            if let text { tv.string = text }
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            tv.perform(sel, with: nil)
            return tv.string
        }
        _ = undo
        check(run(#selector(CodeTextView.sortLines(_:))) == "\n  cherry  \napple\napple\nBanana\npear\n", "sort lines (natural, case-insensitive)")
        check(run(#selector(CodeTextView.uniqueLines(_:)), "a\nb\na\nc\nb\n") == "a\nb\nc\n", "remove duplicates keeps first occurrences")
        check(run(#selector(CodeTextView.removeBlankLines(_:)), "a\n\n  \nb\n") == "a\nb\n", "remove blank lines")
        check(run(#selector(CodeTextView.joinLines(_:)), "one\n  two\nthree\n") == "one two three\n", "join lines")
        check(run(#selector(CodeTextView.camelSnakeToggle(_:)), "userAccountId") == "user_account_id", "camelCase → snake_case")
        check(run(#selector(CodeTextView.camelSnakeToggle(_:)), "user_account_id") == "userAccountId", "snake_case → camelCase")
        check(run(#selector(CodeTextView.prettyJSON(_:)), "{\"b\":1,\"a\":[1,2]}") == "{\n  \"a\" : [\n    1,\n    2\n  ],\n  \"b\" : 1\n}", "format JSON")
        check(run(#selector(CodeTextView.minifyJSON(_:)), "{\n  \"a\" : 1\n}") == "{\"a\":1}", "minify JSON")
        check(run(#selector(CodeTextView.base64Encode(_:)), "hello") == "aGVsbG8=" && run(#selector(CodeTextView.base64Decode(_:))) == "hello", "base64 round trip")
        check(run(#selector(CodeTextView.prettyJSON(_:)), "not json") == "not json", "invalid JSON is left alone")
        // Partial selection: only the selected lines are sorted.
        tv.string = "z\nb\na\ny\n"
        tv.setSelectedRange(NSRange(location: 2, length: 3))
        tv.perform(#selector(CodeTextView.sortLines(_:)), with: nil)
        check(tv.string == "z\na\nb\ny\n", "sort only the selected lines → \(tv.string.debugDescription)")
        print(failures == 0 ? "text tools test passed" : "\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}

/// `Zide --featurestest <dir>`: Markdown styling + checkbox click, test detection (and a real Node test run),
/// compare, hotkey registration, and keep-warm reopen timing. Opens windows without taking focus.
@MainActor
enum FeaturesTest {
    static func run(_ dirPath: String) {
        let dir = URL(fileURLWithPath: dirPath)
        AppDelegate.quiet = true
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print((ok ? "  ok   " : "  FAIL ") + what); if !ok { failures += 1 } }
        func write(_ name: String, _ text: String) -> URL { let u = dir.appendingPathComponent(name); try! text.write(to: u, atomically: true, encoding: .utf8); return u }
        func after(_ t: Double, _ f: @escaping @MainActor () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated(f) } }

        QuickNote.register()
        check(QuickNote.registered, "global ⌃⌥N hotkey registered")

        // Test detection in a JS project (vitest absent → node:test) + real run with Node.
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("proj/.git"), withIntermediateDirectories: true)
        _ = write("proj/package.json", "{\"name\":\"p\",\"type\":\"module\"}")
        let js = write("proj/math.test.js", "import test from 'node:test'\nimport assert from 'node:assert'\n\ntest('adds numbers', () => {\n  assert.equal(1 + 1, 2)\n})\n\ntest('fails on purpose', () => {\n  assert.equal(1, 2)\n})\n")
        let py = write("proj/test_calc.py", "def test_add():\n    assert 1 + 1 == 2\n\nclass TestX:\n    def test_sub(self):\n        assert True\n")
        let go = write("proj/calc_test.go", "package calc\n\nimport \"testing\"\n\nfunc TestAdd(t *testing.T) {\n}\n")
        let sw = write("proj/CalcTests.swift", "import XCTest\n\nfinal class CalcTests: XCTestCase {\n    func testAdd() {\n    }\n    func helper() {}\n}\n")
        let md = write("note.md", "# Shopping\n\n- [ ] milk\n- [x] eggs\n\nSome **bold** and *italic* and `code`.\n\n## Links\n\nSee https://example.com/docs. Brand red is #ff0000 and rgb(0, 128, 255).\n\n```\n# not a heading\n```\n")
        AppDelegate.shared.openPath(js)
        after(0.8) {
            guard let ws = AppDelegate.shared.controllers.last?.workspace else { check(false, "project window"); exit(1) }
            for u in [py, go, sw] { _ = ws.open(u, focus: false) }
            after(0.8) {
                for (u, expect) in [(js, ["adds numbers", "fails on purpose"]), (py, ["test_add", "test_sub"]), (go, ["TestAdd"]), (sw, ["testAdd"])] {
                    guard let d = ws.documents.first(where: { $0.url.standardizedFileURL == u.standardizedFileURL }) else { check(false, "\(u.lastPathComponent) open"); continue }
                    let t = TestFinder.find(d, root: ws.root)
                    check(t.values.map(\.name).sorted() == expect.sorted(), "\(u.lastPathComponent): ▶ on \(t.keys.sorted()) → \(t.values.map(\.name).sorted())")
                    if u == js, let cmd = t.values.first(where: { $0.name == "adds numbers" })?.command {
                        let r = Shell.run("sh", ["-c", cmd], cwd: ws.root)
                        check(r.ok && r.out.contains("pass 1"), "runs one test: `\(cmd)` → exit \(r.status), \(r.out.contains("pass 1") ? "1 passed" : r.out.suffix(120).description)")
                    }
                }
                // Compare a file with different text.
                let other = write("proj/math-old.test.js", "import test from 'node:test'\n")
                let res = Shell.run("git", ["diff", "--no-index", "--no-color", "--", js.path, other.path])
                check(res.out.contains("-test('adds numbers'"), "compare shows the differences")
                // Markdown.
                AppDelegate.shared.openPath(md)
                after(1.0) {
                    guard let mws = AppDelegate.shared.controllers.last?.workspace, let d = mws.active else { check(false, "note window"); exit(1) }
                    let font = d.storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
                    check((font?.pointSize ?? 0) > Prefs.shared.editorFont.pointSize && NSFontManager.shared.traits(of: font!).contains(.boldFontMask), "heading styled bold and larger (\(font?.pointSize ?? 0)pt)")
                    let boldAt = (d.storage.string as NSString).range(of: "bold").location
                    check(NSFontManager.shared.traits(of: d.storage.attribute(.font, at: boldAt, effectiveRange: nil) as! NSFont).contains(.boldFontMask), "**bold** is bold")
                    // Click the checkbox of "milk".
                    let tv = d.primaryEditor.textView
                    let box = (d.storage.string as NSString).range(of: "[ ]").location + 1
                    let lm = tv.layoutManager!
                    var rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: NSRange(location: box, length: 1), actualCharacterRange: nil), in: tv.textContainer!)
                    rect.origin.x += tv.textContainerOrigin.x; rect.origin.y += tv.textContainerOrigin.y
                    let p = tv.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
                    let ev = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: 0, windowNumber: tv.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                    _ = tv.toggleMarkdownCheckbox(ev)
                    check(d.storage.string.contains("- [x] milk"), "clicking [ ] ticks it")
                    let c = d.primaryEditor
                    let linkTexts = c.linkRanges.map { (d.storage.string as NSString).substring(with: $0) }
                    check(linkTexts == ["https://example.com/docs"], "link found (trailing dot dropped): \(linkTexts)")
                    let cols = c.colorSpans.map { EditorController.hex($0.1, alpha: false) }
                    check(cols == ["#ff0000", "#0080ff"], "colour swatches: \(cols)")
                    let allowed = UserDefaults.standard.bool(forKey: "NSAllowContinuousSpellChecking")
                    check(tv.isContinuousSpellCheckingEnabled == (Prefs.shared.spellCheck && allowed), "spell check in Markdown follows the setting (setting \(Prefs.shared.spellCheck), system \(allowed) → \(tv.isContinuousSpellCheckingEnabled))")
                    if let jd = ws.documents.first(where: { $0.url.standardizedFileURL == js.standardizedFileURL }) {
                        check(!jd.primaryEditor.textView.isContinuousSpellCheckingEnabled, "spell check off in code")
                    }
                    let outline = MarkdownOutline.symbols(d).map { "\($0.depth):\($0.name)" }
                    check(outline == ["0:Shopping", "1:Links"], "Markdown outline (skips fenced code): \(outline)")
                    let wasWrap = d.effectiveWrap
                    d.toggleWrap()
                    check(d.effectiveWrap != wasWrap && tv.textContainer!.widthTracksTextView == d.effectiveWrap, "⌥Z toggles soft wrap for this file")
                    d.toggleWrap()
                    d.setLineEnding("\r\n")
                    _ = d.save()
                    let bytes = (try? Data(contentsOf: md)) ?? Data()
                    check(bytes.range(of: Data([13, 10])) != nil, "LF → CRLF converts on save")
                    d.setLineEnding("\n"); _ = d.save()
                    // Keep warm: close everything, then reopen.
                    AppDelegate.quiet = false
                    for c in AppDelegate.shared.controllers { c.window?.close() }
                    after(0.5) {
                        check(NSApp.activationPolicy() == .accessory, "after the last window closes Zide stays running without a Dock icon")
                        let t0 = Date()
                        AppDelegate.shared.application(NSApp, open: [md])
                        let ms = Date().timeIntervalSince(t0) * 1000
                        check(NSApp.activationPolicy() == .regular, String(format: "opening a file brings it back — window in %.0f ms", ms))
                        for c in AppDelegate.shared.controllers { c.workspace.saveAll() }
                        print(failures == 0 ? "features test passed" : "\(failures) failure(s)")
                        exit(failures == 0 ? 0 : 1)
                    }
                }
            }
        }
    }
}

/// `Zide --extrastest <dir>`: calculator, timestamps, Markdown lists, tag auto-close, image viewer, Dock menu.
@MainActor
enum ExtrasTest {
    static func run(_ dirPath: String) {
        let dir = URL(fileURLWithPath: dirPath)
        AppDelegate.quiet = true
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print((ok ? "  ok   " : "  FAIL ") + what); if !ok { failures += 1 } }
        func write(_ name: String, _ text: String) -> URL { let u = dir.appendingPathComponent(name); try! text.write(to: u, atomically: true, encoding: .utf8); return u }
        func after(_ t: Double, _ f: @escaping @MainActor () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated(f) } }

        for (e, want) in [("2+3*4", 14.0), ("(1200 * 12)", 14400), ("200 * 15%", 30), ("2^10", 1024), ("1,234.5 + 1", 1235.5), ("7/2", 3.5), ("-(3-5)*2", 4), ("$40 × 3", 120)] {
            let v = Calc.evaluate(e)
            check(v == want, "calc \(e) = \(v.map(Calc.format) ?? "nil")")
        }
        check(Calc.evaluate("hello") == nil && Calc.evaluate("1/0") == nil && Calc.evaluate("2+") == nil, "calc rejects text, ÷0 and half sums")
        check(Calc.format(0.1 + 0.2) == "0.3", "0.1 + 0.2 shows as 0.3 (\(Calc.format(0.1 + 0.2)))")
        let ts = CodeTextView.timestampSwap("1700000000") ?? ""
        check(CodeTextView.timestampSwap(ts) == "1700000000", "timestamp 1700000000 → \(ts) → back")
        check(CodeTextView.timestampSwap("1700000000000") == ts, "millisecond timestamps too")

        let md = write("list.md", "# Todo\n\n- [x] eggs\n1. first\nrent: 1200 * 12 =\n")
        let html = write("page.html", "<body>\n\n</body>\n")
        let tsx = write("app.tsx", "const a: Array\n")
        // A real PNG to view.
        let png = dir.appendingPathComponent("dot.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try! rep.representation(using: .png, properties: [:])!.write(to: png)
        AppDelegate.shared.openPath(md)
        after(0.8) {
            guard let ws = AppDelegate.shared.controllers.last?.workspace, let d = ws.active else { check(false, "window"); exit(1) }
            let tv = d.primaryEditor.textView
            func caret(after s: String) { let r = (tv.string as NSString).range(of: s); tv.setSelectedRange(NSRange(location: NSMaxRange(r), length: 0)) }
            caret(after: "- [x] eggs"); tv.insertNewline(nil)
            check(tv.string.contains("- [x] eggs\n- [ ] \n"), "Enter after a ticked item starts an unticked one")
            tv.insertNewline(nil)
            check(tv.string.contains("- [x] eggs\n\n1. first"), "Enter on an empty item ends the list")
            caret(after: "1. first"); tv.insertNewline(nil)
            check(tv.string.contains("1. first\n2. "), "numbered list counts up")
            caret(after: "1200 * 12 ="); tv.evaluateMath(nil)
            check(tv.string.contains("rent: 1200 * 12 = 14400"), "⌃⌥= fills in a line ending with =")
            tv.undoManager?.undo()
            for u in [html, tsx, png] { _ = ws.open(u, focus: true) }
            after(0.8) {
                if let h = ws.documents.first(where: { $0.url.lastPathComponent == "page.html" }) {
                    let t = h.primaryEditor.textView
                    t.setSelectedRange(NSRange(location: 7, length: 0))
                    for ch in "<div class=\"box\">" { t.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
                    check(t.string.contains("<div class=\"box\"></div>") && t.selectedRange().location == 7 + 17, "typing <div …> adds </div> after the caret")
                    for ch in "<br>" { t.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
                    check(!t.string.contains("</br>"), "void tags like <br> aren't closed")
                } else { check(false, "html open") }
                if let x = ws.documents.first(where: { $0.url.lastPathComponent == "app.tsx" }) {
                    let t = x.primaryEditor.textView
                    t.setSelectedRange(NSRange(location: 14, length: 0))
                    for ch in "<string>" { t.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
                    check(!t.string.contains("</string>"), "TypeScript generics (Array<string>) aren't treated as tags")
                }
                if let p = ws.documents.first(where: { $0.url.lastPathComponent == "dot.png" }) {
                    check(p.isBinary && p.storage.length == 0 && p.url.mediaKind == .image, "PNG opens in the image viewer, not as text")
                }
                let dock = AppDelegate.shared.applicationDockMenu(NSApp)
                check(dock?.items.first?.title == "New Quick Note", "Dock menu: \(dock?.items.map(\.title).prefix(4).joined(separator: ", ") ?? "none")")
                for c in AppDelegate.shared.controllers { c.workspace.saveAll() }
                print(failures == 0 ? "extras test passed" : "\(failures) failure(s)")
                exit(failures == 0 ? 0 : 1)
            }
        }
    }
}
