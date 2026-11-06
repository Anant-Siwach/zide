import AppKit
import SwiftUI

enum ThemeChoice: String, CaseIterable, Identifiable {
    case system, dark, light, oneDark, dracula, nord, monokai, githubLight, solarizedLight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .oneDark: "One Dark"
        case .githubLight: "GitHub Light"
        case .solarizedLight: "Solarized Light"
        default: rawValue.capitalized
        }
    }
    /// nil = follows the system appearance.
    var isDark: Bool? {
        switch self {
        case .system: nil
        case .light, .githubLight, .solarizedLight: false
        default: true
        }
    }
}

/// Editor + app settings persisted in UserDefaults.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    @Published var theme: ThemeChoice { didSet { d.set(theme.rawValue, forKey: "theme"); Theme.update() } }
    @Published var fontName: String { didSet { d.set(fontName, forKey: "fontName"); changed() } }
    @Published var fontSize: Double { didSet { d.set(fontSize, forKey: "fontSize"); changed() } }
    @Published var lineHeight: Double { didSet { d.set(lineHeight, forKey: "lineHeight"); changed() } }
    @Published var tabWidth: Int { didSet { d.set(tabWidth, forKey: "tabWidth"); changed() } }
    @Published var insertSpaces: Bool { didSet { d.set(insertSpaces, forKey: "insertSpaces") } }
    @Published var wordWrap: Bool { didSet { d.set(wordWrap, forKey: "wordWrap"); changed() } }
    @Published var autosave: Bool { didSet { d.set(autosave, forKey: "autosave") } }
    @Published var autoClosePairs: Bool { didSet { d.set(autoClosePairs, forKey: "autoClosePairs") } }
    @Published var hoverDocs: Bool { didSet { d.set(hoverDocs, forKey: "hoverDocs") } }
    @Published var showMinimapGuides: Bool { didSet { d.set(showMinimapGuides, forKey: "indentGuides"); changed() } }
    @Published var terminalFontSize: Double { didSet { d.set(terminalFontSize, forKey: "terminalFontSize") } }
    @Published var formatOnSave: Bool { didSet { d.set(formatOnSave, forKey: "formatOnSave") } }

    static let editorChanged = Notification.Name("ZideEditorPrefsChanged")

    private init() {
        d.register(defaults: [
            "theme": ThemeChoice.system.rawValue, "fontName": "SF Mono", "fontSize": 13.0, "lineHeight": 1.35,
            "tabWidth": 4, "insertSpaces": true, "wordWrap": false, "autosave": true, "autoClosePairs": true,
            "hoverDocs": true, "indentGuides": true, "terminalFontSize": 12.0, "formatOnSave": false,
        ])
        theme = ThemeChoice(rawValue: d.string(forKey: "theme") ?? "") ?? .system
        fontName = d.string(forKey: "fontName") ?? "SF Mono"
        fontSize = d.double(forKey: "fontSize")
        lineHeight = d.double(forKey: "lineHeight")
        tabWidth = d.integer(forKey: "tabWidth")
        insertSpaces = d.bool(forKey: "insertSpaces")
        wordWrap = d.bool(forKey: "wordWrap")
        autosave = d.bool(forKey: "autosave")
        autoClosePairs = d.bool(forKey: "autoClosePairs")
        hoverDocs = d.bool(forKey: "hoverDocs")
        showMinimapGuides = d.bool(forKey: "indentGuides")
        terminalFontSize = d.double(forKey: "terminalFontSize")
        formatOnSave = d.bool(forKey: "formatOnSave")
    }

    private func changed() { NotificationCenter.default.post(name: Self.editorChanged, object: nil) }

    var editorFont: NSFont {
        let size = CGFloat(fontSize)
        if fontName == "SF Mono" { return .monospacedSystemFont(ofSize: size, weight: .regular) }
        return NSFont(name: fontName, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    var indentUnit: String { insertSpaces ? String(repeating: " ", count: max(1, tabWidth)) : "\t" }

    // MARK: Recent projects

    var recentProjects: [URL] {
        (d.stringArray(forKey: "recentProjects") ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func addRecent(_ url: URL) {
        var list = d.stringArray(forKey: "recentProjects") ?? []
        list.removeAll { $0 == url.path }
        list.insert(url.path, at: 0)
        d.set(Array(list.prefix(20)), forKey: "recentProjects")
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    func removeRecent(_ url: URL) {
        var list = d.stringArray(forKey: "recentProjects") ?? []
        list.removeAll { $0 == url.path }
        d.set(list, forKey: "recentProjects")
    }

    /// Caret offset per file, restored when the file reopens.
    func caret(for url: URL) -> Int? { (d.dictionary(forKey: "carets") as? [String: Int])?[url.path] }
    func setCaret(_ offset: Int, for url: URL) {
        var m = (d.dictionary(forKey: "carets") as? [String: Int]) ?? [:]
        m[url.path] = offset
        if m.count > 800 { m = Dictionary(uniqueKeysWithValues: m.suffix(600).map { ($0.key, $0.value) }) }
        d.set(m, forKey: "carets")
    }

    @Published var trimWhitespace = UserDefaults.standard.object(forKey: "trimWhitespace") as? Bool ?? true { didSet { d.set(trimWhitespace, forKey: "trimWhitespace") } }
    @Published var stickyScroll = UserDefaults.standard.object(forKey: "stickyScroll") as? Bool ?? true { didSet { d.set(stickyScroll, forKey: "stickyScroll"); NotificationCenter.default.post(name: Self.editorChanged, object: nil) } }
    @Published var rainbowBrackets = UserDefaults.standard.object(forKey: "rainbowBrackets") as? Bool ?? true { didSet { d.set(rainbowBrackets, forKey: "rainbowBrackets"); NotificationCenter.default.post(name: Self.editorChanged, object: nil) } }
    @Published var keepWarm = UserDefaults.standard.object(forKey: "keepWarm") as? Bool ?? true { didSet { d.set(keepWarm, forKey: "keepWarm") } }
    @Published var quickNoteHotkey = UserDefaults.standard.object(forKey: "quickNoteHotkey") as? Bool ?? true { didSet { d.set(quickNoteHotkey, forKey: "quickNoteHotkey"); Task { @MainActor in if self.quickNoteHotkey { QuickNote.register() } else { QuickNote.unregister() } } } }
    @Published var markdownStyling = UserDefaults.standard.object(forKey: "markdownStyling") as? Bool ?? true { didSet { d.set(markdownStyling, forKey: "markdownStyling"); NotificationCenter.default.post(name: Self.editorChanged, object: nil) } }
    /// Starts from the system-wide "check spelling while typing" choice; turning it on here overrides that for Zide only.
    @Published var spellCheck = UserDefaults.standard.object(forKey: "spellCheck") as? Bool ?? (UserDefaults.standard.object(forKey: "NSAllowContinuousSpellChecking") as? Bool ?? true) {
        didSet {
            d.set(spellCheck, forKey: "spellCheck")
            if spellCheck { d.set(true, forKey: "NSAllowContinuousSpellChecking") } else { d.removeObject(forKey: "NSAllowContinuousSpellChecking") }
            NotificationCenter.default.post(name: Self.editorChanged, object: nil)
        }
    }
    @Published var showWhitespace = UserDefaults.standard.bool(forKey: "showWhitespace") { didSet { d.set(showWhitespace, forKey: "showWhitespace"); NotificationCenter.default.post(name: Self.editorChanged, object: nil) } }
    @Published var followLogs = UserDefaults.standard.object(forKey: "followLogs") as? Bool ?? true { didSet { d.set(followLogs, forKey: "followLogs") } }

    /// Files opened recently (any project), newest first — File ▸ Open Recent and the Dock menu.
    var recentFiles: [URL] { (d.stringArray(forKey: "recentFiles") ?? []).map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) } }
    func addRecentFile(_ url: URL) {
        // Self-tests open throwaway files; keep them out of the user's list.
        if CommandLine.arguments.contains(where: { $0.hasSuffix("test") || $0.hasPrefix("--uishot") }) { return }
        var list = d.stringArray(forKey: "recentFiles") ?? []
        list.removeAll { $0 == url.path }
        list.insert(url.path, at: 0)
        d.set(Array(list.prefix(25)), forKey: "recentFiles")
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }
    func clearRecentFiles() { d.removeObject(forKey: "recentFiles"); NSDocumentController.shared.clearRecentDocuments(nil) }

    @Published var inlayHints = UserDefaults.standard.object(forKey: "inlayHints") as? Bool ?? true { didSet { d.set(inlayHints, forKey: "inlayHints"); NotificationCenter.default.post(name: Self.editorChanged, object: nil) } }
    @Published var showBlame = UserDefaults.standard.object(forKey: "showBlame") as? Bool ?? true { didSet { d.set(showBlame, forKey: "showBlame") } }

    /// Paths of files that were open per project, restored when the project reopens.
    func openFiles(for root: URL) -> [String] { d.stringArray(forKey: "open:" + root.path) ?? [] }
    func setOpenFiles(_ paths: [String], for root: URL) { d.set(paths, forKey: "open:" + root.path) }
}
