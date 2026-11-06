import AppKit

/// Menus with JetBrains (macOS keymap) shortcuts. Actions travel the responder chain:
/// text view → window → WorkspaceWindowController → AppDelegate.
@MainActor
enum MainMenu {
    private static func key(_ code: Int) -> String { String(UnicodeScalar(code)!) }

    static func build() -> NSMenu {
        let main = NSMenu()

        main.addItem(sub("Zide", [
            item("About Zide", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", #selector(AppDelegate.showSettings(_:)), ","),
            .separator(),
            item("Hide Zide", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Zide", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        main.addItem(sub("File", [
            item("New File…", #selector(WorkspaceWindowController.newFile(_:)), "n"),
            item("New Scratch File…", #selector(WorkspaceWindowController.newScratchFile(_:)), "n", [.command, .shift]),
            item("New Project…", #selector(AppDelegate.newProject)),
            item("Open…", #selector(AppDelegate.openPanel), "o"),
            RecentMenu.item(),
            item("New Quick Note", #selector(AppDelegate.newQuickNote(_:)), "n", [.control, .option]),
            item("Clone Repository…", #selector(AppDelegate.cloneRepository)),
            item("Open Remote Folder (SSH)…", #selector(AppDelegate.openRemote(_:))),
            item("Pull from Server", #selector(WorkspaceWindowController.remotePull(_:))),
            item("Upload All to Server", #selector(WorkspaceWindowController.remotePushAll(_:))),
            item("Welcome Screen", #selector(AppDelegate.showWelcome(_:))),
            .separator(),
            item("Save", #selector(WorkspaceWindowController.saveDocument(_:)), "s"),
            item("Save All", #selector(WorkspaceWindowController.saveAllDocuments(_:)), "s", [.command, .option]),
            .separator(),
            item("Close Tab", #selector(WorkspaceWindowController.closeTab(_:)), "w"),
            item("Reopen Closed Tab", #selector(WorkspaceWindowController.reopenClosedTab(_:)), "t", [.command, .option, .shift]),
            item("Copy File Path", #selector(CodeTextView.copyFilePath(_:)), "c", [.command, .option, .shift]),
            item("Close Project", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
            .separator(),
            item("Reveal in Finder", #selector(WorkspaceWindowController.revealInFinder(_:))),
            item("Local History…", #selector(WorkspaceWindowController.showLocalHistory(_:))),
            item("Show Changes in This File", #selector(WorkspaceWindowController.showFileChanges(_:)), "d", [.command, .option]),
            item("Compare with Clipboard", #selector(WorkspaceWindowController.compareWithClipboard(_:))),
            item("Compare with File…", #selector(WorkspaceWindowController.compareWithFile(_:))),
            item("Export as PDF…", #selector(WorkspaceWindowController.exportPDF(_:)), "p", [.command, .option]),
        ]))

        main.addItem(sub("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            item("Extend Selection", #selector(CodeTextView.extendSelection(_:)), key(NSUpArrowFunctionKey), [.option]),
            item("Insert Date & Time", #selector(CodeTextView.insertDateTime(_:)), "d", [.control, .option]),
            item("Calculate", #selector(CodeTextView.evaluateMath(_:)), "=", [.control, .option]),
            .separator(),
            finder("Find…", .showFindInterface, "f"),
            finder("Replace…", .showReplaceInterface, "r"),
            finder("Find Next", .nextMatch, "g"),
            finder("Find Previous", .previousMatch, "g", [.command, .shift]),
            item("Find in Files…", #selector(WorkspaceWindowController.findInFiles(_:)), "f", [.command, .shift]),
            item("Replace in Files…", #selector(WorkspaceWindowController.replaceInFiles(_:)), "r", [.command, .shift]),
            .separator(),
            item("Comment with Line Comment", #selector(CodeTextView.toggleComment(_:)), "/"),
            item("Duplicate Line or Selection", #selector(CodeTextView.duplicateLine(_:)), "d"),
            item("Delete Line", #selector(CodeTextView.deleteLine(_:)), key(NSBackspaceCharacter == 8 ? 8 : 8)),
            item("Move Line Up", #selector(CodeTextView.moveLineUp(_:)), key(NSUpArrowFunctionKey), [.option, .shift]),
            item("Move Line Down", #selector(CodeTextView.moveLineDown(_:)), key(NSDownArrowFunctionKey), [.option, .shift]),
            .separator(),
            sub("Transform", [
                item("Sort Lines", #selector(CodeTextView.sortLines(_:))),
                item("Sort Lines Descending", #selector(CodeTextView.sortLinesDescending(_:))),
                item("Reverse Lines", #selector(CodeTextView.reverseLines(_:))),
                item("Shuffle Lines", #selector(CodeTextView.shuffleLines(_:))),
                item("Remove Duplicate Lines", #selector(CodeTextView.uniqueLines(_:))),
                item("Remove Blank Lines", #selector(CodeTextView.removeBlankLines(_:))),
                item("Trim Whitespace", #selector(CodeTextView.trimLines(_:))),
                item("Join Lines", #selector(CodeTextView.joinLines(_:)), "j", [.control]),
                .separator(),
                item("UPPERCASE", #selector(CodeTextView.upperCase(_:)), "u", [.command, .shift]),
                item("lowercase", #selector(CodeTextView.lowerCase(_:))),
                item("Title Case", #selector(CodeTextView.titleCase(_:))),
                item("camelCase ↔ snake_case", #selector(CodeTextView.camelSnakeToggle(_:))),
                .separator(),
                item("Format JSON", #selector(CodeTextView.prettyJSON(_:)), "j", [.command, .option, .shift]),
                item("Minify JSON", #selector(CodeTextView.minifyJSON(_:))),
                item("Base64 Encode", #selector(CodeTextView.base64Encode(_:))),
                item("Base64 Decode", #selector(CodeTextView.base64Decode(_:))),
                item("URL Encode", #selector(CodeTextView.urlEncode(_:))),
                item("URL Decode", #selector(CodeTextView.urlDecode(_:))),
                item("Unix Timestamp ⇄ Date", #selector(CodeTextView.convertTimestamp(_:))),
            ]),
            .separator(),
            item("Add Selection for Next Occurrence", #selector(CodeTextView.selectNextOccurrence(_:)), "g", [.control]),
            item("Select All Occurrences", #selector(CodeTextView.selectAllOccurrences(_:)), "g", [.control, .command]),
            item("Add Caret Above", #selector(CodeTextView.addCaretAbove(_:)), key(NSUpArrowFunctionKey), [.option, .command]),
            item("Add Caret Below", #selector(CodeTextView.addCaretBelow(_:)), key(NSDownArrowFunctionKey), [.option, .command]),
        ]))

        main.addItem(sub("View", [
            item("Project", #selector(WorkspaceWindowController.toggleProject(_:)), "1"),
            item("Commit", #selector(WorkspaceWindowController.toggleCommit(_:)), "0"),
            item("Structure", #selector(WorkspaceWindowController.toggleStructure(_:)), "7"),
            item("Run", #selector(WorkspaceWindowController.toggleRunPanel(_:)), "4"),
            item("Problems", #selector(WorkspaceWindowController.toggleProblems(_:)), "6"),
            item("Git Log", #selector(WorkspaceWindowController.toggleGitLog(_:)), "9"),
            item("Terminal", #selector(WorkspaceWindowController.toggleTerminal(_:)), key(NSF12FunctionKey), [.option]),
            item("New Terminal Tab", #selector(WorkspaceWindowController.newTerminal(_:)), "t", [.command, .shift]),
            item("Debug", #selector(WorkspaceWindowController.toggleDebugPanel(_:)), "5"),
            item("TODO", #selector(WorkspaceWindowController.toggleTodo(_:))),
            item("Distraction-Free Mode", #selector(WorkspaceWindowController.toggleZen(_:)), "z", [.command, .control]),
            item("Soft Wrap", #selector(CodeTextView.toggleSoftWrap(_:)), "z", [.option]),
            item("Show Whitespace", #selector(CodeTextView.toggleShowWhitespace(_:)), "w", [.command, .option, .shift]),
            item("Hide All Tool Windows", #selector(WorkspaceWindowController.hideAllPanels(_:)), key(NSF12FunctionKey), [.command, .shift]),
            .separator(),
            item("Split Right", #selector(WorkspaceWindowController.splitRight(_:)), "\\", [.command]),
            item("Move Tab to Other Split", #selector(WorkspaceWindowController.moveToOtherSplit(_:)), "\\", [.command, .shift]),
            item("Focus Other Split", #selector(WorkspaceWindowController.focusOtherSplit(_:)), "`", [.control]),
            item("Unsplit", #selector(WorkspaceWindowController.unsplit(_:))),
            item("Markdown Preview", #selector(WorkspaceWindowController.toggleMarkdownPreview(_:)), "p", [.command, .shift]),
            item("Live Web Preview", #selector(WorkspaceWindowController.toggleLivePreview(_:)), "p", [.command, .option, .shift]),
            item("Show Notebooks as JSON", #selector(WorkspaceWindowController.toggleNotebookJSON(_:))),
            .separator(),
            item("Increase Font Size", #selector(WorkspaceWindowController.zoomIn(_:)), "=", [.command, .control]),
            item("Decrease Font Size", #selector(WorkspaceWindowController.zoomOut(_:)), "-", [.command, .control]),
            item("Reset Font Size", #selector(WorkspaceWindowController.zoomReset(_:)), "0", [.command, .option]),
        ]))

        main.addItem(sub("Navigate", [
            item("Search Everywhere (⇧⇧)", #selector(WorkspaceWindowController.searchEverywhere(_:)), "o", [.command, .option, .shift]),
            item("Go to File…", #selector(WorkspaceWindowController.goToFile(_:)), "o", [.command, .shift]),
            item("Go to Symbol…", #selector(WorkspaceWindowController.goToSymbol(_:)), "o", [.command, .option]),
            item("Find Action…", #selector(WorkspaceWindowController.findAction(_:)), "a", [.command, .shift]),
            item("Recent Files", #selector(WorkspaceWindowController.recentFiles(_:)), "e"),
            item("Go to Line:Column…", #selector(CodeTextView.goToLine(_:)), "l"),
            .separator(),
            item("Go to Definition", #selector(CodeTextView.goToDefinitionAction(_:)), "b"),
            item("Find Usages", #selector(CodeTextView.findUsages(_:)), key(NSF7FunctionKey), [.option]),
            item("File Structure", #selector(CodeTextView.fileStructure(_:)), key(NSF12FunctionKey)),
            item("Select in Project View", #selector(WorkspaceWindowController.selectInProject(_:)), key(NSF1FunctionKey), [.option]),
            .separator(),
            item("Back", #selector(WorkspaceWindowController.goBack(_:)), "["),
            item("Forward", #selector(WorkspaceWindowController.goForward(_:)), "]"),
            item("Next Highlighted Error", #selector(CodeTextView.nextError(_:)), key(NSF2FunctionKey), []),
            item("Previous Highlighted Error", #selector(CodeTextView.previousError(_:)), key(NSF2FunctionKey), [.shift]),
            .separator(),
            item("Toggle Bookmark", #selector(CodeTextView.toggleBookmark(_:)), key(NSF3FunctionKey), []),
            item("Show Bookmarks", #selector(WorkspaceWindowController.showBookmarks(_:)), key(NSF3FunctionKey), [.command]),
        ]))

        main.addItem(sub("Code", [
            item("Code Completion", #selector(CodeTextView.triggerCompletion(_:)), " ", [.control]),
            item("Show Context Actions", #selector(CodeTextView.showContextActions(_:)), "\r", [.option]),
            item("Quick Documentation", #selector(CodeTextView.quickDocumentation(_:)), key(NSF1FunctionKey), []),
            .separator(),
            item("Rename…", #selector(CodeTextView.renameSymbol(_:)), key(NSF6FunctionKey), [.shift]),
            item("Reformat Code", #selector(CodeTextView.reformatCode(_:)), "l", [.command, .option]),
            .separator(),
            .separator(),
            item("Collapse", #selector(CodeTextView.foldCode(_:)), "-"),
            item("Expand", #selector(CodeTextView.unfoldCode(_:)), "="),
            item("Collapse All", #selector(CodeTextView.foldAllCode(_:)), "-", [.command, .shift]),
            item("Expand All", #selector(CodeTextView.unfoldAllCode(_:)), "=", [.command, .shift]),
            .separator(),
            item("Restart Language Server", #selector(WorkspaceWindowController.restartServer(_:))),
            .separator(),
            item("Send HTTP Request", #selector(WorkspaceWindowController.sendHTTPRequest(_:)), "\r", [.control, .option]),
            item("Connect to Postgres…", #selector(AppDelegate.connectPostgres(_:))),
            item("Open Database File…", #selector(AppDelegate.openDatabaseFile(_:))),
        ]))

        main.addItem(sub("Run", [
            item("Run", #selector(WorkspaceWindowController.runSelected(_:)), "r", [.control]),
            item("Run Current File", #selector(WorkspaceWindowController.runCurrentFile(_:)), "r", [.control, .shift]),
            item("Debug", #selector(WorkspaceWindowController.startDebug(_:)), "d", [.control]),
            item("Stop", #selector(WorkspaceWindowController.stopAll(_:)), key(NSF2FunctionKey), [.command]),
            .separator(),
            item("Toggle Breakpoint", #selector(CodeTextView.toggleBreakpointAtCaret(_:)), key(NSF8FunctionKey), [.command]),
            item("Resume Program", #selector(WorkspaceWindowController.debugResume(_:)), "r", [.command, .option]),
            item("Step Over", #selector(WorkspaceWindowController.debugStepOver(_:)), key(NSF8FunctionKey), []),
            item("Step Into", #selector(WorkspaceWindowController.debugStepInto(_:)), key(NSF7FunctionKey), []),
            item("Step Out", #selector(WorkspaceWindowController.debugStepOut(_:)), key(NSF8FunctionKey), [.shift]),
            .separator(),
            item("Edit Configurations…", #selector(WorkspaceWindowController.editRunConfigs(_:))),
        ]))

        main.addItem(sub("AI", [
            item("AI Assistant", #selector(WorkspaceWindowController.toggleAssistant(_:)), "i"),
            item("Explain Selection", #selector(CodeTextView.aiExplain(_:)), "e", [.command, .option]),
            item("Fix Problem at Caret", #selector(CodeTextView.aiFix(_:)), "f", [.command, .option, .control]),
            item("Write Commit Message", #selector(WorkspaceWindowController.aiCommitMessage(_:))),
            .separator(),
            item("Inline Completions", #selector(AppDelegate.toggleInlineCompletions(_:))),
            item("AI Settings…", #selector(AppDelegate.showAISettings(_:))),
        ]))

        main.addItem(sub("Git", [
            item("Commit…", #selector(WorkspaceWindowController.gitCommit(_:)), "k"),
            item("Push", #selector(WorkspaceWindowController.gitPush(_:)), "k", [.command, .shift]),
            item("Pull", #selector(WorkspaceWindowController.gitPull(_:)), "t"),
        ]))

        let window = sub("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu

        let help = sub("Help", [
            item("Zide Help", #selector(AppDelegate.showHelp(_:)), "?"),
            item("Keyboard Shortcuts", #selector(AppDelegate.showShortcuts(_:)), "/", [.command, .control]),
            item("Live Templates", #selector(AppDelegate.showTemplatesHelp(_:))),
            .separator(),
            item("Languages & Debuggers…", #selector(AppDelegate.showLanguageSettings(_:))),
            item("Install 'zide' Command-Line Launcher", #selector(AppDelegate.installCLIFromMenu(_:))),
            item("Welcome Screen", #selector(AppDelegate.showWelcome(_:))),
        ])
        main.addItem(help)
        NSApp.helpMenu = help.submenu   // adds the standard macOS menu-search field
        return main
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        return i
    }

    private static func finder(_ title: String, _ action: NSTextFinder.Action, _ key: String, _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = item(title, #selector(NSResponder.performTextFinderAction(_:)), key, mods)
        i.tag = action.rawValue
        return i
    }

    private static func sub(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        items.forEach(m.addItem)
        parent.submenu = m
        return parent
    }
}


/// File ▸ Open Recent: recent files and projects, rebuilt each time the menu opens.
@MainActor
final class RecentMenu: NSObject, NSMenuDelegate {
    static let shared = RecentMenu()
    static func item() -> NSMenuItem {
        let i = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let m = NSMenu(title: "Open Recent")
        m.delegate = shared
        i.submenu = m
        return i
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let files = Prefs.shared.recentFiles.prefix(15), projects = Prefs.shared.recentProjects.prefix(8)
        func add(_ url: URL, folder: Bool) {
            let i = NSMenuItem(title: url.lastPathComponent, action: #selector(open(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = url
            i.toolTip = (url.path as NSString).abbreviatingWithTildeInPath
            i.image = NSWorkspace.shared.icon(forFile: url.path)
            i.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(i)
            _ = folder
        }
        if files.isEmpty && projects.isEmpty { menu.addItem(NSMenuItem(title: "No Recent Items", action: nil, keyEquivalent: "")) }
        files.forEach { add($0, folder: false) }
        if !files.isEmpty && !projects.isEmpty { menu.addItem(.separator()) }
        projects.forEach { add($0, folder: true) }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clear), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    @objc private func open(_ sender: NSMenuItem) { if let u = sender.representedObject as? URL { AppDelegate.shared.openPath(u) } }
    @objc private func clear() { Prefs.shared.clearRecentFiles() }
}
