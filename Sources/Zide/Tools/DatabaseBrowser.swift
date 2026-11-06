import AppKit
import SQLite3
import SwiftUI

// MARK: - Database browser: open a SQLite file like any other file, or connect to Postgres (through psql). Tables,
// schemas, a SQL editor and a result grid. SQLite opens read-only unless you allow changes.

struct QueryResult {
    var columns: [String] = []
    var rows: [[String]] = []
    var message = ""
    var error: String?
    var time = 0.0
}

protocol DBBackend: AnyObject {
    var title: String { get }
    func tables() -> [String]
    func schema(_ table: String) -> String
    func run(_ sql: String, limit: Int) -> QueryResult
    func quote(_ name: String) -> String
}

final class SQLiteBackend: DBBackend {
    let url: URL
    private var db: OpaquePointer?
    let writable: Bool
    var title: String { url.lastPathComponent }

    init?(url: URL, writable: Bool) {
        self.url = url; self.writable = writable
        let flags = writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
    }
    deinit { sqlite3_close(db) }

    func quote(_ n: String) -> String { "\"" + n.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    func tables() -> [String] {
        run("SELECT name FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY type, name", limit: 10_000).rows.map { $0[0] }
    }
    func schema(_ t: String) -> String {
        run("SELECT sql FROM sqlite_master WHERE name = '\(t.replacingOccurrences(of: "'", with: "''"))'", limit: 1).rows.first?.first ?? ""
    }

    private let lock = NSLock()

    func run(_ sql: String, limit: Int) -> QueryResult {
        // One statement at a time per connection, and the SQL text kept alive while SQLite walks it.
        lock.lock(); defer { lock.unlock() }
        var r = QueryResult()
        let t0 = Date()
        var changed = 0
        sql.withCString { start in
            var rest: UnsafePointer<CChar>? = start
            // Runs every statement; the last one with columns fills the grid.
            while let p = rest, p.pointee != 0 {
                var stmt: OpaquePointer?
                var tail: UnsafePointer<CChar>?
                guard sqlite3_prepare_v2(db, p, -1, &stmt, &tail) == SQLITE_OK else { r.error = String(cString: sqlite3_errmsg(db)); break }
                rest = tail
                guard let s = stmt else { continue }       // whitespace / comment only
                defer { sqlite3_finalize(s) }
                let n = Int(sqlite3_column_count(s))
                var cols: [String] = [], rows: [[String]] = []
                for i in 0..<n { cols.append(String(cString: sqlite3_column_name(s, Int32(i)))) }
                var step = sqlite3_step(s)
                while step == SQLITE_ROW {
                    if rows.count < limit {
                        rows.append((0..<n).map { i in
                            switch sqlite3_column_type(s, Int32(i)) {
                            case SQLITE_NULL: return "NULL"
                            case SQLITE_BLOB: return "<\(sqlite3_column_bytes(s, Int32(i))) bytes>"
                            default: return sqlite3_column_text(s, Int32(i)).map { String(cString: $0) } ?? ""
                            }
                        })
                    }
                    step = sqlite3_step(s)
                }
                if step != SQLITE_DONE { r.error = String(cString: sqlite3_errmsg(db)); break }
                if n > 0 { r.columns = cols; r.rows = rows } else { changed += Int(sqlite3_changes(db)) }
            }
        }
        r.time = Date().timeIntervalSince(t0)
        if r.error == nil { r.message = r.columns.isEmpty ? "Done — \(changed) row\(changed == 1 ? "" : "s") changed" : "\(r.rows.count)\(r.rows.count == limit ? "+" : "") row\(r.rows.count == 1 ? "" : "s")" }
        return r
    }
}

/// Postgres through the psql command-line tool (no driver needed).
final class PostgresBackend: DBBackend {
    let connection: String
    let psql: String
    var title: String { connection.replacingOccurrences(of: #"://([^:@/]+):[^@]*@"#, with: "://$1@", options: .regularExpression) }

    init?(connection: String) {
        let candidates = [Env.which("psql"), "/opt/homebrew/bin/psql", "/usr/local/bin/psql"].compactMap { $0 }
            + ((try? FileManager.default.contentsOfDirectory(atPath: "/usr/local/opt")) ?? []).filter { $0.hasPrefix("postgresql") }.map { "/usr/local/opt/\($0)/bin/psql" }
            + ((try? FileManager.default.contentsOfDirectory(atPath: "/opt/homebrew/opt")) ?? []).filter { $0.hasPrefix("postgresql") }.map { "/opt/homebrew/opt/\($0)/bin/psql" }
        guard let p = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        psql = p; self.connection = connection
    }

    func quote(_ n: String) -> String { n.split(separator: ".").map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ".") }

    private func exec(_ args: [String], input: String? = nil) -> (out: String, err: String, ok: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: psql)
        p.arguments = [connection, "-X", "-v", "ON_ERROR_STOP=1"] + args
        let o = Pipe(), e = Pipe(), i = Pipe()
        p.standardOutput = o; p.standardError = e; p.standardInput = i
        guard (try? p.run()) != nil else { return ("", "psql couldn't start", false) }
        if let input { i.fileHandleForWriting.write(Data(input.utf8)) }
        try? i.fileHandleForWriting.close()
        let out = o.fileHandleForReading.readDataToEndOfFile(), err = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self), p.terminationStatus == 0)
    }

    func tables() -> [String] {
        let r = exec(["-At", "-c", "SELECT table_schema || '.' || table_name FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema') ORDER BY 1"])
        return r.out.split(separator: "\n").map(String.init)
    }
    func schema(_ t: String) -> String {
        let parts = t.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "" }
        let r = exec(["-At", "-c", "SELECT column_name || ' ' || data_type || CASE WHEN is_nullable = 'NO' THEN ' NOT NULL' ELSE '' END FROM information_schema.columns WHERE table_schema = '\(parts[0])' AND table_name = '\(parts[1])' ORDER BY ordinal_position"])
        return "TABLE \(t) (\n  " + r.out.split(separator: "\n").joined(separator: ",\n  ") + "\n)"
    }
    func run(_ sql: String, limit: Int) -> QueryResult {
        let t0 = Date()
        // -q drops command tags ("INSERT 0 1"), leaving only query output.
        let r = exec(["-q", "--csv", "-P", "pager=off", "-f", "-"], input: sql)
        var q = QueryResult()
        q.time = Date().timeIntervalSince(t0)
        if !r.ok { q.error = r.err.trimmingCharacters(in: .whitespacesAndNewlines); return q }
        let rows = CSV.parse(r.out)
        if rows.isEmpty { q.message = "Done" }
        else {
            q.columns = rows[0]; q.rows = Array(rows.dropFirst().prefix(limit))
            q.message = "\(q.rows.count) row\(q.rows.count == 1 ? "" : "s")"
        }
        return q
    }
}

enum CSV {
    /// RFC 4180: quoted fields with "" escapes and newlines.
    static func parse(_ s: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var it = s.makeIterator()
        var pending: Character? = nil
        while let c = pending ?? it.next() {
            pending = nil
            if quoted {
                if c == "\"" { if let n = it.next() { if n == "\"" { field.append("\"") } else { quoted = false; pending = n } } else { quoted = false } }
                else { field.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { row.append(field); field = "" }
            else if c == "\n" || c == "\r\n" { row.append(field); rows.append(row); row = []; field = "" }
            else if c != "\r" { field.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
    static func write(_ cols: [String], _ rows: [[String]]) -> String {
        func q(_ f: String) -> String { f.contains(",") || f.contains("\"") || f.contains("\n") ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f }
        return ([cols] + rows).map { $0.map(q).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }
}

@MainActor
final class DatabaseModel: ObservableObject {
    @Published var backend: DBBackend?
    @Published var tables: [String] = []
    @Published var selected: String?
    @Published var schema = ""
    @Published var sql = ""
    @Published var result = QueryResult()
    @Published var running = false
    @Published var writable = false
    let fileURL: URL?

    init(file: URL) { fileURL = file; open() }
    init(backend: DBBackend) { fileURL = nil; self.backend = backend; refresh() }

    func open() {
        guard let u = fileURL else { return }
        backend = SQLiteBackend(url: u, writable: writable)
        if backend == nil { result.error = "This file couldn't be opened as a SQLite database." }
        refresh()
    }
    func refresh() {
        guard let b = backend else { return }
        Task {
            let t = await Task.detached { b.tables() }.value
            tables = t
            if selected == nil, let f = t.first { show(f) }
        }
    }
    func show(_ t: String) {
        guard let b = backend else { return }
        selected = t
        sql = "SELECT * FROM \(b.quote(t)) LIMIT 500;"
        Task { schema = await Task.detached { b.schema(t) }.value }
        run()
    }
    func run() {
        guard let b = backend, !running else { return }
        running = true
        let q = sql
        Task {
            result = await Task.detached { b.run(q, limit: 5000) }.value
            running = false
            if result.columns.isEmpty && result.error == nil { refresh() }     // tables may have changed
        }
    }
    func exportCSV() {
        let p = NSSavePanel(); p.nameFieldStringValue = (selected ?? "result") + ".csv"; p.allowedContentTypes = [.commaSeparatedText]
        guard p.runModal() == .OK, let u = p.url else { return }
        try? CSV.write(result.columns, result.rows).write(to: u, atomically: true, encoding: .utf8)
    }

    // Postgres connections
    private static var windows: [NSWindow] = []
    static func connectPostgres() {
        let a = NSAlert()
        a.messageText = "Connect to Postgres"
        a.informativeText = "Connection string, e.g. postgres://user@localhost:5432/mydb (password: ~/.pgpass or postgres://user:pass@…)."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        f.stringValue = UserDefaults.standard.string(forKey: "lastPostgres") ?? "postgres://localhost:5432/postgres"
        a.accessoryView = f
        a.addButton(withTitle: "Connect"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        UserDefaults.standard.set(f.stringValue, forKey: "lastPostgres")
        guard let b = PostgresBackend(connection: f.stringValue) else {
            let e = NSAlert(); e.messageText = "psql not found"; e.informativeText = "Install it with: brew install libpq (or postgresql)."; e.runModal(); return
        }
        show(DatabaseModel(backend: b), title: b.title)
    }
    static func show(_ m: DatabaseModel, title: String) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = title; w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: DatabaseView(model: m))
        w.center(); windows.append(w); w.makeKeyAndOrderFront(nil)
    }
}

struct DatabaseView: View {
    @ObservedObject var model: DatabaseModel
    @ObservedObject var theme = ThemeObserver.shared

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(model.backend?.title ?? "Database").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                }.padding(8)
                List(model.tables, id: \.self, selection: Binding(get: { model.selected }, set: { if let t = $0 { model.show(t) } })) { t in
                    Label(t, systemImage: "tablecells").font(.system(size: 12))
                }
                if model.fileURL != nil {
                    Toggle("Allow changes", isOn: Binding(get: { model.writable }, set: { model.writable = $0; model.open() }))
                        .toggleStyle(.checkbox).font(.caption).padding(8).help("Opened read-only by default, so a stray UPDATE can't change the file")
                }
            }
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 360)
            VSplitView {
                VStack(spacing: 0) {
                    TextEditor(text: $model.sql).font(.system(size: 13, design: .monospaced)).scrollContentBackground(.hidden).padding(6)
                        .background(theme.palette.background.swiftUI)
                    HStack {
                        Button { model.run() } label: { Label("Run", systemImage: "play.fill") }.keyboardShortcut(.return, modifiers: .command).disabled(model.running)
                        if model.running { ProgressView().controlSize(.small) }
                        if let e = model.result.error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(3) }
                        else { Text("\(model.result.message) · \(String(format: "%.0f ms", model.result.time * 1000))").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Export CSV…") { model.exportCSV() }.disabled(model.result.columns.isEmpty)
                    }.padding(6)
                }
                .frame(minHeight: 110, idealHeight: 150)
                VStack(spacing: 0) {
                    ResultGrid(columns: model.result.columns, rows: model.result.rows)
                    if !model.schema.isEmpty {
                        Divider()
                        ScrollView { Text(model.schema).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).padding(6).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 80)
                    }
                }
            }
        }
    }
}

/// A native table for any number of columns (fast for thousands of rows).
struct ResultGrid: NSViewRepresentable {
    let columns: [String]
    let rows: [[String]]

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var rows: [[String]] = []
        func numberOfRows(in t: NSTableView) -> Int { rows.count }
        func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
            guard let col, let i = Int(col.identifier.rawValue), rows.indices.contains(row) else { return nil }
            let v = (t.makeView(withIdentifier: NSUserInterfaceItemIdentifier("cell"), owner: nil) as? NSTextField) ?? {
                let f = NSTextField(labelWithString: ""); f.identifier = NSUserInterfaceItemIdentifier("cell"); f.lineBreakMode = .byTruncatingTail
                f.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular); return f
            }()
            let s = i < rows[row].count ? rows[row][i] : ""
            v.stringValue = s; v.textColor = s == "NULL" ? .tertiaryLabelColor : .labelColor
            v.toolTip = s.count > 40 ? String(s.prefix(2000)) : nil
            return v
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let t = NSTableView(); t.usesAlternatingRowBackgroundColors = true; t.rowHeight = 20; t.allowsColumnReordering = true
        t.dataSource = context.coordinator; t.delegate = context.coordinator
        t.columnAutoresizingStyle = .noColumnAutoresizing
        let s = NSScrollView(); s.documentView = t; s.hasVerticalScroller = true; s.hasHorizontalScroller = true
        return s
    }
    func updateNSView(_ s: NSScrollView, context: Context) {
        guard let t = s.documentView as? NSTableView else { return }
        context.coordinator.rows = rows
        if t.tableColumns.map(\.title) != columns {
            for c in t.tableColumns { t.removeTableColumn(c) }
            for (i, name) in columns.enumerated() {
                let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(i)")); c.title = name
                let sample = rows.prefix(50).map { i < $0.count ? $0[i].count : 0 }.max() ?? 0
                c.width = CGFloat(min(320, max(70, max(name.count, sample) * 8))); t.addTableColumn(c)
            }
        }
        t.reloadData()
    }
}

extension URL {
    var isDatabase: Bool {
        guard ["sqlite", "sqlite3", "db", "db3", "sdb"].contains(pathExtension.lowercased()) else { return false }
        // The SQLite file header.
        guard let h = try? FileHandle(forReadingFrom: self) else { return false }
        defer { try? h.close() }
        return h.readData(ofLength: 16) == Data("SQLite format 3\0".utf8)
    }
}

/// A SQLite file opened from the project.
struct DatabaseFileView: View {
    @StateObject private var model: DatabaseModel
    init(url: URL) { _model = StateObject(wrappedValue: DatabaseModel(file: url)) }
    var body: some View { DatabaseView(model: model) }
}
