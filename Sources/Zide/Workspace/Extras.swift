import AppKit
import CryptoKit

/// JetBrains-style bookmarks: F3 toggles one on the caret line, ⌘F3 lists them.
@MainActor
final class Bookmarks: ObservableObject {
    unowned let workspace: Workspace
    @Published private(set) var lines: [String: Set<Int>] = [:]   // path → 1-based lines

    init(workspace: Workspace) {
        self.workspace = workspace
        if let saved = UserDefaults.standard.dictionary(forKey: key) as? [String: [Int]] { lines = saved.mapValues(Set.init) }
    }

    private var key: String { "bookmarks:" + workspace.root.path }

    func lines(for url: URL) -> Set<Int> { lines[url.standardizedFileURL.path] ?? [] }

    func toggle(_ url: URL, line: Int) {
        let p = url.standardizedFileURL.path
        var set = lines[p] ?? []
        if set.contains(line) { set.remove(line) } else { set.insert(line) }
        lines[p] = set.isEmpty ? nil : set
        save()
    }

    func shift(_ url: URL, fromLine: Int, delta: Int, removed: ClosedRange<Int>?) {
        let p = url.standardizedFileURL.path
        guard delta != 0, let set = lines[p] else { return }
        var out = Set<Int>()
        for l in set {
            if let removed, removed.contains(l), l != removed.lowerBound { continue }
            out.insert(l > fromLine ? max(1, l + delta) : l)
        }
        lines[p] = out.isEmpty ? nil : out
        save()
    }

    private func save() { UserDefaults.standard.set(lines.mapValues { Array($0) }, forKey: key) }

    func showList() {
        let ws = workspace
        var items: [PaletteItem] = []
        for (path, set) in lines.sorted(by: { $0.key < $1.key }) {
            let url = URL(fileURLWithPath: path)
            for line in set.sorted() {
                let text = Workspace.line(line - 1, of: url).trimmingCharacters(in: .whitespaces)
                items.append(PaletteItem(title: "\(url.lastPathComponent):\(line)", subtitle: text, icon: "bookmark.fill", iconColor: .orange) {
                    ws.openUsage(UsageItem(url: url, line: line - 1, column: 0, length: 0, preview: ""))
                })
            }
        }
        if items.isEmpty { ws.flash("No bookmarks — press F3 on a line to add one"); return }
        ws.palette.show(title: "Bookmarks", items: items)
    }
}

/// Saves a copy of each file on save, so you can go back (like JetBrains Local History).
enum LocalHistory {
    static let maxPerFile = 50

    static func dir(for url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zide/LocalHistory/\(hash)", isDirectory: true)
    }

    static func snapshot(_ url: URL, text: String, root: URL) {
        DispatchQueue.global(qos: .utility).async {
            let d = dir(for: url)
            let fm = FileManager.default
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
            let existing = versions(url)
            // Skip identical consecutive snapshots.
            if let last = existing.first, (try? String(contentsOf: last.file, encoding: .utf8)) == text { return }
            guard text.utf8.count < 2_000_000 else { return }
            let name = String(Int(Date().timeIntervalSince1970 * 1000)) + ".txt"
            try? text.write(to: d.appendingPathComponent(name), atomically: true, encoding: .utf8)
            for old in existing.dropFirst(maxPerFile - 1) { try? fm.removeItem(at: old.file) }
        }
    }

    struct Version: Identifiable { let file: URL; let date: Date; var id: URL { file } }

    static func versions(_ url: URL) -> [Version] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir(for: url), includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { f in
            guard let ms = Double(f.deletingPathExtension().lastPathComponent) else { return nil }
            return Version(file: f, date: Date(timeIntervalSince1970: ms / 1000))
        }.sorted { $0.date > $1.date }
    }
}

/// Scratch files live outside projects (JetBrains ⇧⌘N).
enum Scratches {
    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Zide/Scratches", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static let kinds: [(String, String)] = [("Plain text", "txt"), ("Markdown", "md"), ("Swift", "swift"), ("Python", "py"), ("JavaScript", "js"),
                                             ("TypeScript", "ts"), ("JSON", "json"), ("Shell", "sh"), ("SQL", "sql"), ("Rust", "rs"), ("Go", "go"), ("C++", "cpp")]

    static func create(ext: String) -> URL {
        var n = 1
        var url = dir.appendingPathComponent("scratch.\(ext)")
        while FileManager.default.fileExists(atPath: url.path) { n += 1; url = dir.appendingPathComponent("scratch_\(n).\(ext)") }
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }
}
