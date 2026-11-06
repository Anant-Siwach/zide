import AppKit
import PDFKit
import WebKit

/// `ZIDE_AI_MOCK=http://127.0.0.1:<port>/v1 ZIDE_SSH=<fakessh> ZIDE_TESTDIR=<dir> Zide --newfeaturestest <dir> <port> <pg-port> -aiInlineCompletions YES`
/// AI assistant (tool loop, edits, inline completion, commit message), HTTP client, SQLite + Postgres, notebooks, live
/// preview, Markdown → PDF, SSH remote folders, palette tasks/text, refactor preview. Everything happens in <dir>.
@MainActor
enum NewFeaturesTest {
    static func run(_ dirPath: String, port: String, pgPort: String) {
        let dir = URL(fileURLWithPath: dirPath)
        AppDelegate.quiet = true
        var failures = 0
        setvbuf(stdout, nil, _IOLBF, 0)
        func check(_ ok: Bool, _ what: String) { print((ok ? "  ok   " : "  FAIL ") + what); if !ok { failures += 1 } }
        func write(_ name: String, _ text: String) -> URL {
            let u = dir.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! text.write(to: u, atomically: true, encoding: .utf8); return u
        }
        func wait(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }
        let proj = dir.appendingPathComponent("proj")
        let calc = write("proj/calc.py", "def add(a, b):\n    return a - b\n\nprint(add(2, 3))\n")
        _ = write("proj/package.json", "{\"name\":\"p\",\"scripts\":{\"test\":\"node -e 1\",\"lint\":\"echo lint\"}}")
        _ = write("proj/README.md", "# Demo\n\nSome **bold** text.\n\n| Name | Score |\n|---|---|\n| Anant | 42 |\n")
        _ = write("proj/site/index.html", "<!doctype html><html><head><link rel=stylesheet href=style.css></head><body><h1>Hi</h1><script src=app.js></script></body></html>")
        let css = write("proj/site/style.css", "body { background: rgb(9, 9, 9); }\n")
        _ = write("proj/site/app.js", "console.log('hello from app.js'); missingFunction();\n")
        _ = write("proj/api.http", "@base = http://127.0.0.1:\(port)\n@token = secret42\n\n### Get echo\nGET {{base}}/echo?x=1\nX-Token: {{token}}\n\n### Post JSON\nPOST {{base}}/echo\nContent-Type: application/json\n\n{\"n\": {{$randomInt}}}\n")
        _ = Shell.run("git", ["init", "-q"], cwd: proj)
        _ = Shell.run("git", ["-c", "user.email=t@t", "-c", "user.name=t", "add", "."], cwd: proj)
        _ = Shell.run("git", ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"], cwd: proj)

        AppDelegate.shared.openPath(proj)
        Task {
            await wait(1.0)
            guard let ws = AppDelegate.shared.controllers.last?.workspace else { check(false, "project window"); exit(1) }

            // 1. Assistant: reads the file through a tool, proposes an edit, applies it.
            let a = ws.assistant
            a.agentMode = false
            a.ask("Fix the bug in calc.py")
            while a.busy { await wait(0.1) }
            let edit = a.edits.values.first
            check(a.turns.last?.text.contains("Fixed") == true && edit?.old == "    return a - b", "assistant read calc.py and proposed a fix: “\(a.turns.last?.text ?? "")”")
            if let e = edit {
                a.apply(e.id)
                let d = ws.documents.first { $0.url.standardizedFileURL == calc.standardizedFileURL }
                check(d?.text.contains("return a + b") == true && d?.isDirty == true, "Apply changes the editor (unsaved, undoable)")
                ws.saveAll()
            }
            check(a.url("../outside.txt") == nil && a.url("/etc/passwd") == nil, "tools can't reach files outside the project")
            let tooMany = await a.run("edit_file", ["path": "calc.py", "old_string": "", "new_string": "x"])
            check(tooMany.contains("already exists"), "an edit can't silently overwrite a whole file")

            // 2. Inline completion (ghost text) and Tab to accept.
            let d = ws.open(calc, focus: true)!
            let tv = d.editor.textView
            tv.setSelectedRange(NSRange(location: d.storage.length, length: 0))
            tv.insertText("print(\"x\", ", replacementRange: NSRange(location: NSNotFound, length: 0))
            tv.insertText("my_", replacementRange: NSRange(location: NSNotFound, length: 0))
            for _ in 0..<40 where !tv.ghost.isVisible { await wait(0.1) }
            check(tv.ghost.suggestion == "name)", "ghost text suggested: \(tv.ghost.suggestion ?? "nothing")")
            tv.insertTab(nil)
            check(d.text.hasSuffix("print(\"x\", my_name)") && !tv.ghost.isVisible, "Tab inserts it: …\(d.text.suffix(30).debugDescription)")
            check(GhostText.clean("```python\nfoo(1)\n```", prefix: "x = foo", suffix: "") == "(1)" && GhostText.clean("bar)", prefix: "f(", suffix: ")") == "bar", "suggestions are cleaned (fences, echoed text, closing brackets)")
            ws.saveAll()

            // 3. Commit message.
            a.commitMessage()
            for _ in 0..<40 where ws.git.message.hasPrefix("✨") || ws.git.message.isEmpty { await wait(0.1) }
            check(ws.git.message.hasPrefix("Fix add() to return the sum"), "commit message written: “\(ws.git.message.components(separatedBy: "\n").first ?? "")”")

            // 4. HTTP client.
            let parsed = HTTPFile.parse(try! String(contentsOf: proj.appendingPathComponent("api.http"), encoding: .utf8))
            check(parsed.requests.count == 2 && parsed.requests[0].name == "Get echo" && parsed.vars["token"] == "secret42", "parsed .http: \(parsed.requests.map(\.name))")
            let r1 = await HTTPFile.send(parsed.requests[0], vars: parsed.vars), r2 = await HTTPFile.send(parsed.requests[1], vars: parsed.vars)
            check(r1.status == 200 && r1.body.contains("\"token\" : \"secret42\"") && r1.body.contains("\"path\" : \"/echo?x=1\""), "GET with variables and headers (pretty JSON)")
            check(r2.body.contains("\"method\" : \"POST\"") && r2.body.contains("application/json") && !r2.body.contains("randomInt"), "POST with a JSON body and {{$randomInt}}")

            // 5. SQLite (read-only by default) and Postgres.
            let dbURL = dir.appendingPathComponent("proj/data.sqlite")
            _ = Shell.run("sqlite3", [dbURL.path, "CREATE TABLE players(name TEXT, rating INT); INSERT INTO players VALUES ('Anant', 1800), ('Ravi', 1650); CREATE VIEW top AS SELECT * FROM players WHERE rating > 1700;"])
            check(dbURL.isDatabase && !calc.isDatabase, "SQLite files recognised by their header")
            let dm = DatabaseModel(file: dbURL)
            for _ in 0..<30 where dm.result.rows.isEmpty { await wait(0.1) }
            check(dm.tables == ["players", "top"] && dm.result.rows.count == 2 && dm.result.columns == ["name", "rating"], "tables \(dm.tables), first table shown: \(dm.result.rows)")
            dm.sql = "INSERT INTO players VALUES ('X', 1)"; dm.run(); while dm.running { await wait(0.05) }
            check(dm.result.error?.contains("readonly") == true, "read-only by default: \(dm.result.error ?? "-")")
            dm.writable = true; dm.open()
            dm.sql = "INSERT INTO players VALUES ('X', 1); SELECT count(*) AS n FROM players;"; dm.run(); while dm.running { await wait(0.05) }
            check(dm.result.rows.first?.first == "3", "with “Allow changes”: insert then count → \(dm.result.rows)")
            if let pg = PostgresBackend(connection: "postgres://test@localhost:\(pgPort)/postgres") {
                let c = pg.run("DROP TABLE IF EXISTS games; CREATE TABLE games(id serial primary key, white text, result text); INSERT INTO games(white, result) VALUES ('Carlsen, M', '1-0'), ('Gukesh \"D\"', '½-½');", limit: 100)
                let s = pg.run("SELECT white, result FROM games ORDER BY id", limit: 100)
                check(c.error == nil && s.columns == ["white", "result"] && s.rows == [["Carlsen, M", "1-0"], ["Gukesh \"D\"", "½-½"]], "Postgres through psql: \(s.rows) \(c.error ?? s.error ?? "")")
                check(pg.tables().contains("public.games") && pg.schema("public.games").contains("white text"), "Postgres tables and schema")
                check(pg.run("SELECT nope FROM games", limit: 10).error?.contains("does not exist") == true, "Postgres errors are shown")
            } else { check(false, "psql found") }

            // 6. Notebook: shared variables, last value, print, error; saved as nbformat 4.
            do {
            let nbURL = write("proj/analysis.ipynb", "")
            let nbDoc = ws.open(nbURL, focus: false)!
            let nb = NotebookModel(workspace: ws, doc: nbDoc)
            nb.cells = [NBCell(type: "markdown", source: "# Analysis"), NBCell(type: "code", source: "x = 21\nprint('x is', x)"), NBCell(type: "code", source: "x * 2"), NBCell(type: "code", source: "1 / 0")]
            for c in nb.cells where c.type == "code" { nb.run(c.id); while nb.cells.first(where: { $0.id == c.id })?.running == true { await wait(0.05) } }
            check(nb.cells[1].outputs.first?.text == "x is 21\n" && nb.cells[2].outputs.first?.text == "42" && nb.cells[2].count == 2, "cells share variables: print → “x is 21”, last value → 42")
            check(nb.cells[3].outputs.first?.type == "error" && nb.cells[3].outputs.first!.text.contains("ZeroDivisionError"), "errors show the traceback")
            // (A notebook view may also be showing this file; save this model's cells directly.)
            nb.flush(); _ = nbDoc.save()
            let saved = try? JSONSerialization.jsonObject(with: Data(contentsOf: nbURL)) as? [String: Any]
            let cells = saved?["cells"] as? [[String: Any]]
            check(saved?["nbformat"] as? Int == 4 && cells?.count == 4 && ((cells?[2]["outputs"] as? [[String: Any]])?.first?["data"] as? [String: Any])?["text/plain"] as? String == "42", "saved as a standard .ipynb (nbformat 4) with outputs")
            nb.kernel.stop()
            }

            // 7. Live preview, with an unsaved CSS edit and console capture.
            let html = ws.open(proj.appendingPathComponent("site/index.html"), focus: false)!
            let cssDoc = ws.open(css, focus: false)!
            cssDoc.storage.replaceCharacters(in: NSRange(location: 0, length: cssDoc.storage.length), with: "body { background: rgb(1, 2, 3); }\n")
            let pm = ws.preview
            let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
            host.contentView = pm.webView
            pm.follow(html)
            var bg = ""
            for _ in 0..<50 where bg != "rgb(1, 2, 3)" { await wait(0.1); bg = (try? await pm.webView.evaluateJavaScript("getComputedStyle(document.body).backgroundColor") as? String) ?? "" }
            check(bg == "rgb(1, 2, 3)", "preview uses the unsaved CSS edit: \(bg)")
            check(pm.console.contains { $0.contains("hello from app.js") } && pm.console.contains { $0.hasPrefix("error") && $0.contains("missingFunction") }, "console output and errors captured: \(pm.console)")

            // 8. Markdown → PDF.
            let pdf = dir.appendingPathComponent("readme.pdf")
            var done = false
            PDFExporter.export(html: MarkdownHTML.document(try! String(contentsOf: proj.appendingPathComponent("README.md"), encoding: .utf8), title: "README"), baseURL: proj, to: pdf) { _ in done = true }
            for _ in 0..<100 where !done { await wait(0.1) }
            let text = PDFDocument(url: pdf)?.string ?? ""
            check(text.contains("Demo") && text.contains("Anant") && text.contains("bold"), "Markdown exported to PDF (\(PDFDocument(url: pdf)?.pageCount ?? 0) page): heading, table and text")
            check(MarkdownHTML.inline("a **b** `c` [d](e)") == "a <strong>b</strong> <code>c</code> <a href=\"e\">d</a>", "Markdown inline formatting")

            // 9. Remote folder over SSH (stand-in ssh runs commands locally).
            let server = write("server/app/main.py", "print('remote')\n").deletingLastPathComponent()
            _ = write("server/app/lib/util.py", "X = 1\n")
            _ = write("server/app/node_modules/big.js", "skip me\n")
            let spec = RemoteSpec(host: "devbox", path: server.path)
            var opened = false
            RemoteConnect.open(spec) { ok, msg in opened = ok; if !ok { print("    \(msg)") } }
            for _ in 0..<50 where !opened { await wait(0.1) }
            let mirror = Remote.mirror(for: spec)
            check(opened && FileManager.default.fileExists(atPath: mirror.appendingPathComponent("lib/util.py").path) && !FileManager.default.fileExists(atPath: mirror.appendingPathComponent("node_modules").path), "remote folder copied (node_modules skipped) to \(mirror.path.replacingOccurrences(of: dirPath, with: "…"))")
            await wait(0.8)
            if let rws = AppDelegate.shared.controllers.first(where: { $0.workspace.root.standardizedFileURL == mirror.standardizedFileURL })?.workspace, let r = rws.remote {
                let doc = rws.open(mirror.appendingPathComponent("main.py"), focus: false)!
                doc.storage.replaceCharacters(in: NSRange(location: 0, length: doc.storage.length), with: "print('edited in Zide')\n")
                doc.markEdited()
                rws.save(doc)
                for _ in 0..<40 where (try? String(contentsOf: server.appendingPathComponent("main.py"), encoding: .utf8)) != "print('edited in Zide')\n" { await wait(0.1) }
                check((try? String(contentsOf: server.appendingPathComponent("main.py"), encoding: .utf8)) == "print('edited in Zide')\n", "saving uploads the file to the server \(r.status) | local: \((try? String(contentsOf: mirror.appendingPathComponent("main.py"), encoding: .utf8)) ?? "-")")
                _ = write("server/app/lib/util.py", "X = 2  # changed on the server\n")
                let util = rws.open(mirror.appendingPathComponent("lib/util.py"), focus: false)!
                while r.syncing { await wait(0.05) }
                r.pull()
                for _ in 0..<40 where !util.text.contains("changed on the server") { await wait(0.1) }
                check(util.text.contains("changed on the server"), "server changes are pulled into the open file")
                check(Remote.remoteShell(spec, command: "make test").contains("'cd '\\''\(server.path)'\\'' && make test'") || Remote.remoteShell(spec, command: "make test").contains("cd '\\''"), "terminals and runs execute on the server: \(Remote.remoteShell(spec, command: "make test").suffix(60))")
            } else { check(false, "remote workspace opened") }

            // 10. Palette: tasks and text search.
            ws.runner.detect()
            ws.palette.open(.tasks)
            check(ws.palette.results.map(\.title).contains("npm test") && ws.palette.results.map(\.title).contains("npm lint"), "Tasks: \(ws.palette.results.map(\.title))")
            ws.palette.mode = .text; ws.palette.query = "my_name"
            for _ in 0..<30 where ws.palette.results.isEmpty { await wait(0.1) }
            check(ws.palette.results.first?.subtitle.hasPrefix("calc.py:") == true, "Text search: \(ws.palette.results.map(\.subtitle))")
            ws.palette.close()

            // 11. Refactor preview: two files, one excluded.
            let f1 = write("proj/a.py", "total = 1\nprint(total)\n"), f2 = write("proj/b.py", "from a import total\n")
            func e(_ l: Int, _ c: Int) -> JSON { ["range": ["start": ["line": l, "character": c], "end": ["line": l, "character": c + 5]], "newText": "count"] }
            let we: JSON = ["changes": [f1.absoluteString: [e(0, 0), e(1, 6)], f2.absoluteString: [e(0, 14)]]]
            let rp = RefactorPreviewModel(workspace: ws, edit: we, title: "Rename")
            check(rp.changes.count == 3 && rp.changes[0].after == "count = 1" && rp.changes[2].after == "from a import count", "preview lists each change: \(rp.changes.map(\.after))")
            rp.excluded = [f2.standardizedFileURL]
            rp.apply()
            await wait(0.3)
            ws.saveAll()
            check((try? String(contentsOf: f1, encoding: .utf8)) == "count = 1\nprint(count)\n" && (try? String(contentsOf: f2, encoding: .utf8)) == "from a import total\n", "only the ticked file changed")

            print(failures == 0 ? "new features test passed" : "\(failures) failure(s)")
            exit(failures == 0 ? 0 : 1)
        }
    }
}

/// Minimal notebook repro: `Zide --nbtest <dir>`.
@MainActor enum NBTest {
    static func run(_ dirPath: String) {
        setvbuf(stdout, nil, _IOLBF, 0)
        AppDelegate.quiet = true
        let dir = URL(fileURLWithPath: dirPath).appendingPathComponent("nbp")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let nbURL = dir.appendingPathComponent("a.ipynb")
        try? "".write(to: nbURL, atomically: true, encoding: .utf8)
        AppDelegate.shared.openPath(dir)
        Task {
            try? await Task.sleep(for: .seconds(1))
            guard let ws = AppDelegate.shared.controllers.last?.workspace else { print("no ws"); exit(1) }
            let doc = ws.open(nbURL, focus: false)!
            let nb = NotebookModel(workspace: ws, doc: doc)
            nb.cells = [NBCell(type: "code", source: "print(1)")]
            let env = ProcessInfo.processInfo.environment
            if env["NO_RUN"] == nil {
                nb.run(nb.cells[0].id)
                while nb.cells[0].running { try? await Task.sleep(for: .milliseconds(50)) }
                print("ran: \(nb.cells[0].outputs.map(\.text))")
            }
            nb.flush(); print("flushed")
            if env["NO_SAVE"] == nil {
                if env["RAW_SAVE"] != nil { _ = doc.save() } else { ws.save(doc) }
                print("saved")
            }
            try? await Task.sleep(for: .seconds(3))
            print("nb test done")
            exit(0)
        }
    }
}

/// `ZIDE_AI_MOCK=… Zide --agenttest <dir>`: agent mode — edit applied and saved, one command approved, one skipped, revert.
@MainActor enum AgentTest {
    static func run(_ dirPath: String) {
        setvbuf(stdout, nil, _IOLBF, 0)
        AppDelegate.quiet = true
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print((ok ? "  ok   " : "  FAIL ") + what); if !ok { failures += 1 } }
        let proj = URL(fileURLWithPath: dirPath).appendingPathComponent("agent")
        try? FileManager.default.createDirectory(at: proj.appendingPathComponent("important"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: proj.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let calc = proj.appendingPathComponent("calc.py")
        try? "def add(a, b):\n    return a - b\n\nprint(add(2, 3))\n".write(to: calc, atomically: true, encoding: .utf8)
        AppDelegate.shared.openPath(proj)
        Task {
            try? await Task.sleep(for: .seconds(1))
            guard let ws = AppDelegate.shared.controllers.last?.workspace else { print("no ws"); exit(1) }
            let a = ws.assistant
            a.agentMode = true
            a.ask("Fix calc.py and check it works")
            var approved = 0, skipped = 0
            while a.busy {
                for (id, c) in a.commands where c.state == .waiting {
                    if c.command.hasPrefix("rm") { a.skip(id); skipped += 1 } else { a.approve(id); approved += 1 }
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            let disk = (try? String(contentsOf: calc, encoding: .utf8)) ?? ""
            check(disk.contains("return a + b"), "the edit was applied and saved to disk")
            let ran = a.commands.values.first { $0.command == "python3 calc.py" }
            check(approved == 1 && ran?.exitCode == 0 && ran?.output.trimmingCharacters(in: .whitespacesAndNewlines) == "5", "approved command ran: exit \(ran?.exitCode ?? -1), output “\(ran?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")”")
            check(skipped == 1 && FileManager.default.fileExists(atPath: proj.appendingPathComponent("important").path), "skipped command did not run (folder still there)")
            check(a.turns.last?.text.contains("printed: Exit code 0. | 5") == true && a.turns.last?.text.contains("skipped") == true, "the AI saw the output and the skip: \(a.turns.last?.text.prefix(120) ?? "")")
            if let e = a.edits.values.first { a.revert(e.id) }
            try? await Task.sleep(for: .milliseconds(300))
            check(((try? String(contentsOf: calc, encoding: .utf8)) ?? "").contains("return a - b"), "Revert puts the old code back on disk")
            // Stop while a command waits: it's skipped, nothing runs.
            a.ask("Fix calc.py and check it works")
            while !a.commands.values.contains(where: { $0.state == .waiting }) && a.busy { try? await Task.sleep(for: .milliseconds(50)) }
            a.stop()
            try? await Task.sleep(for: .milliseconds(300))
            check(!a.busy && !a.commands.values.contains { $0.state == .waiting }, "Stop cancels a waiting command")
            a.agentMode = false        // don't leave the setting on for the next run
            print(failures == 0 ? "agent test passed" : "\(failures) failure(s)")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
