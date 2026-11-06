import AppKit

/// Owns the text view stack for one document and implements the language-aware features.
@MainActor
final class EditorController: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
    weak var document: EditorDocument?
    let pane: Int
    let scrollView = NSScrollView()
    let textView: CodeTextView
    let layoutManager = NSLayoutManager()
    let container: NSTextContainer
    private(set) var ruler: LineNumberRuler!
    lazy var completion = CompletionController(editor: self)
    lazy var info = InfoPopup(editor: self)
    private var tokens: [Token] = []
    private var highlightVersion = -1
    private var highlightPending = false
    private var bracketRanges: [NSRange] = []
    private var occurrenceRanges: [NSRange] = []
    private var occurrenceTimer: Timer?
    private var observers: [Any] = []
    /// Folded (hidden) character ranges, sorted.
    var folds: [NSRange] = []
    /// Foldable regions: 0-based start line → range that would be hidden.
    var foldRegions: [Int: NSRange] = [:] { didSet { updateStickyHeaders() } }
    var stickyView: StickyHeaderView?
    /// Test functions in this file (1-based line → how to run it), shown as ▶ in the gutter.
    var testTargets: [Int: TestTarget] = [:]
    var linkRanges: [NSRange] = []
    var colorSpans: [(NSRange, NSColor)] = []
    var tokensSnapshot: [Token] { tokens }

    var workspace: Workspace? { document?.workspace }

    /// 1-based line where the debugger is paused in this file, if any.
    var executionLine: Int? {
        guard let doc = document, let p = workspace?.debug.executionPoint, p.url == doc.url else { return nil }
        return p.line
    }

    func didFocus() {
        guard let ws = workspace, ws.panes.indices.contains(pane), ws.focusedPane != pane else { return }
        ws.focusedPane = pane
    }

    func linesChanged(startLine: Int, delta: Int, removed: ClosedRange<Int>?) {
        guard let doc = document, let ws = workspace else { return }
        ws.debug.shiftBreakpoints(doc.url, fromLine: startLine, delta: delta, removed: removed)
        ws.bookmarks.shift(doc.url, fromLine: startLine, delta: delta, removed: removed)
    }

    init(document: EditorDocument, pane: Int) {
        self.document = document
        self.pane = pane
        container = NSTextContainer(size: NSSize(width: 1e7, height: 1e7))
        layoutManager.allowsNonContiguousLayout = true
        layoutManager.addTextContainer(container)
        document.storage.addLayoutManager(layoutManager)
        textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        super.init()
        textView.controller = self
        layoutManager.delegate = self
        configure()
        observers.append(NotificationCenter.default.addObserver(forName: Prefs.editorChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPrefs() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: Theme.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTheme() }
        })
        // Re-highlight on any character edit, including edits typed in the other split pane.
        observers.append(NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: document.storage, queue: .main) { [weak self] n in
            guard let storage = n.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated {
                self?.scheduleHighlight(delay: 0.03)
                self?.ruler?.needsDisplay = true
            }
        })
        rehighlight()
    }

    /// Detaches this (secondary) editor from the shared text storage.
    func teardown() {
        completion.hide()
        info.hide()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        scrollView.removeFromSuperview()
        document?.storage.removeLayoutManager(layoutManager)
    }

    private func configure() {
        let tv = textView
        tv.delegate = self
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false   // turned on for notes in applyPrefs
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.displaysLinkToolTips = false
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isEditable = !(document?.isBinary ?? false)

        scrollView.documentView = tv
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        if let doc = document {
            ruler = LineNumberRuler(textView: tv, document: doc)
            scrollView.verticalRulerView = ruler
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
        }
        applyPrefs()
        applyTheme()
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ruler?.needsDisplay = true; self?.updateStickyHeaders() }
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        let sticky = StickyHeaderView(frame: NSRect(x: 0, y: 0, width: 400, height: 0))
        sticky.controller = self
        sticky.isHidden = true
        sticky.autoresizingMask = [.width]
        scrollView.addSubview(sticky)
        stickyView = sticky
    }

    private func applyPrefs() {
        let prefs = Prefs.shared
        if !prefs.inlayHints { document?.clearInlayHints() } else { scheduleInlayHints(delay: 0.2) }
        let font = prefs.editorFont
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = CGFloat(prefs.lineHeight)
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        para.defaultTabInterval = space * CGFloat(max(1, document?.tabWidth ?? prefs.tabWidth))
        para.tabStops = []
        textView.font = font
        textView.defaultParagraphStyle = para
        textView.typingAttributes = [.font: font, .paragraphStyle: para, .foregroundColor: Theme.current.text]
        let storage = textView.textStorage!
        storage.beginEditing()
        storage.addAttributes([.font: font, .paragraphStyle: para], range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        // Notes and Markdown wrap like a text editor; code follows the setting.
        // Spelling for notes and Markdown only (code is full of "misspellings").
        textView.isContinuousSpellCheckingEnabled = prefs.spellCheck && (document?.language.isProse ?? false)
        if document?.effectiveWrap ?? prefs.wordWrap {
            container.widthTracksTextView = true
            textView.isHorizontallyResizable = false
            container.size = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
            scrollView.hasHorizontalScroller = false
        } else {
            container.widthTracksTextView = false
            textView.isHorizontallyResizable = true
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            scrollView.hasHorizontalScroller = true
        }
        ruler?.updateThickness()
        ruler?.needsDisplay = true
        textView.needsDisplay = true
    }

    private func applyTheme() {
        let p = Theme.current
        textView.backgroundColor = p.background
        scrollView.backgroundColor = p.background
        textView.insertionPointColor = p.cursor
        textView.selectedTextAttributes = [.backgroundColor: p.selection]
        textView.typingAttributes[.foregroundColor] = p.text
        let storage = textView.textStorage!
        storage.addAttribute(.foregroundColor, value: p.text, range: NSRange(location: 0, length: storage.length))
        applyTokens()
        applyDiagnostics()
        textView.needsDisplay = true
        ruler?.needsDisplay = true
    }

    // MARK: Highlighting

    private static var hintTimers: [ObjectIdentifier: Timer] = [:]

    func scheduleInlayHints(delay: TimeInterval = 0.9) {
        guard pane == 0, let doc = document else { return }
        let key = ObjectIdentifier(doc)
        Self.hintTimers[key]?.invalidate()
        Self.hintTimers[key] = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak doc] _ in
            // Hop through the main queue: the timer can fire inside a nested run loop (e.g. during a save), where
            // asserting main-actor isolation directly crashes.
            DispatchQueue.main.async { MainActor.assumeIsolated { doc?.refreshInlayHints() } }
        }
    }

    func rehighlight() {
        highlightVersion = -1
        scheduleHighlight(delay: 0)
    }

    private func scheduleHighlight(delay: TimeInterval) {
        guard let doc = document, !highlightPending else { return }
        guard !doc.isTooLarge, doc.language.lexer != .plain else {
            // Deferred: this runs inside the text storage's edit notification, before the layout manager has caught up,
            // and touching its attributes then throws (seen when a whole plain-text file is replaced by code).
            tokens = []
            highlightPending = true
            DispatchQueue.main.async { [weak self] in self?.highlightPending = false; self?.applyTokens() }
            return
        }
        highlightPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let doc = self.document else { return }
            self.highlightPending = false
            let version = doc.version
            let lang = doc.language
            let text = Array(doc.storage.string.utf16)
            DispatchQueue.global(qos: .userInitiated).async {
                let toks = Lexer.tokenize(lang, text)
                DispatchQueue.main.async {
                    guard doc.version == version else { self.scheduleHighlight(delay: 0.02); return }
                    self.tokens = toks
                    self.highlightVersion = version
                    self.applyTokens()
                }
            }
        }
    }

    private func applyTokens() {
        let lm = layoutManager
        let length = textView.textStorage?.length ?? 0
        let full = NSRange(location: 0, length: length)
        let p = Theme.current
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        var escapes: [Token] = []
        for t in tokens {
            guard Int(t.start) + Int(t.length) <= length else { continue }
            if t.kind == .escape { escapes.append(t); continue }
            lm.addTemporaryAttribute(.foregroundColor, value: p.color(t.kind), forCharacterRange: t.range)
        }
        for t in escapes where Int(t.start) + Int(t.length) <= length {
            lm.addTemporaryAttribute(.foregroundColor, value: p.color(.escape), forCharacterRange: t.range)
        }
        colorBrackets(length: length)
        styleMarkdown(length: length)
        decorateLinksAndColors(length: length)
        if let doc = document, let ws = doc.workspace { testTargets = TestFinder.find(doc, root: ws.root); ruler?.needsDisplay = true }
        computeFoldRegions()
    }

    /// Markdown while editing: headings larger and bold, **bold**, *italic*, `code` tinted, markers dimmed.
    /// Fonts go into the text storage (not saved to disk; attribute changes don't trigger re-highlighting).
    private func styleMarkdown(length: Int) {
        guard let doc = document, doc.language.lexer == .markdown, length < 500_000 else { return }
        let storage = doc.storage
        let base = Prefs.shared.editorFont
        let ns = storage.string as NSString
        let fm = NSFontManager.shared
        storage.beginEditing()
        storage.addAttribute(.font, value: base, range: NSRange(location: 0, length: length))
        storage.removeAttribute(.strikethroughStyle, range: NSRange(location: 0, length: length))
        guard Prefs.shared.markdownStyling else { storage.endEditing(); return }
        let dim = Theme.current.color(.comment)
        func each(_ pattern: String, _ body: (NSTextCheckingResult) -> Void) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
            re.enumerateMatches(in: ns as String, range: NSRange(location: 0, length: length)) { m, _, _ in if let m { body(m) } }
        }
        each(#"^(#{1,6})[ \t]+.*$"#) { m in
            let level = m.range(at: 1).length
            let size = base.pointSize * [1.45, 1.3, 1.18, 1.08, 1.0, 1.0][level - 1]
            storage.addAttribute(.font, value: fm.convert(fm.convert(base, toSize: size), toHaveTrait: .boldFontMask), range: m.range)
            layoutManager.addTemporaryAttribute(.foregroundColor, value: dim, forCharacterRange: m.range(at: 1))
        }
        each(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#) { m in
            storage.addAttribute(.font, value: fm.convert(base, toHaveTrait: .boldFontMask), range: m.range)
            for r in [NSRange(location: m.range.location, length: 2), NSRange(location: NSMaxRange(m.range) - 2, length: 2)] { layoutManager.addTemporaryAttribute(.foregroundColor, value: dim, forCharacterRange: r) }
        }
        each(#"(?<![\*\w])([\*_])(?=[^\s\*_])([^\*_\n]+?)(?<=\S)\1(?![\*\w])"#) { m in
            storage.addAttribute(.font, value: fm.convert(base, toHaveTrait: .italicFontMask), range: m.range)
        }
        each(#"`[^`\n]+`"#) { m in
            layoutManager.addTemporaryAttribute(.backgroundColor, value: Theme.current.bracket.withAlphaComponent(0.6), forCharacterRange: m.range)
        }
        // Done items: struck through and dimmed.
        each(#"^\s*[-*+] \[[xX]\] (.*)$"#) { m in
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
            layoutManager.addTemporaryAttribute(.foregroundColor, value: dim, forCharacterRange: m.range(at: 1))
        }
        storage.endEditing()
    }

    /// Rainbow brackets: (), [], {} coloured by nesting depth, skipping strings and comments.
    private func colorBrackets(length: Int) {
        guard Prefs.shared.rainbowBrackets, length < 1_500_000, let ns = document?.storage.string as NSString? else { return }
        let colors = Theme.isDark
            ? [NSColor(srgbRed: 0.98, green: 0.80, blue: 0.30, alpha: 1), NSColor(srgbRed: 0.85, green: 0.55, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.40, green: 0.70, blue: 1.0, alpha: 1)]
            : [NSColor(srgbRed: 0.72, green: 0.52, blue: 0.0, alpha: 1), NSColor(srgbRed: 0.55, green: 0.20, blue: 0.70, alpha: 1), NSColor(srgbRed: 0.10, green: 0.40, blue: 0.80, alpha: 1)]
        var skip = IndexSet()
        for t in tokens where t.kind == .string || t.kind == .comment || t.kind == .regex { skip.insert(integersIn: Int(t.start)..<min(length, Int(t.start + t.length))) }
        var buf = [unichar](repeating: 0, count: length)
        ns.getCharacters(&buf, range: NSRange(location: 0, length: length))
        var depth = 0
        for i in 0..<length {
            let c = buf[i]
            guard c == 40 || c == 41 || c == 91 || c == 93 || c == 123 || c == 125, !skip.contains(i) else { continue }
            if c == 41 || c == 93 || c == 125 { depth = max(0, depth - 1) }
            layoutManager.addTemporaryAttribute(.foregroundColor, value: colors[depth % colors.count], forCharacterRange: NSRange(location: i, length: 1))
            if c == 40 || c == 91 || c == 123 { depth += 1 }
        }
    }

    func token(at offset: Int) -> Token? {
        tokens.last { Int($0.start) <= offset && offset < Int($0.start + $0.length) && $0.kind != .escape }
    }

    // MARK: Diagnostics

    func applyDiagnostics() {
        guard document != nil else { return }
        guard let doc = document else { return }
        let lm = layoutManager
        let length = textView.textStorage?.length ?? 0
        let full = NSRange(location: 0, length: length)
        lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
        lm.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
        let p = Theme.current
        let ns = textView.string as NSString
        for d in doc.diagnostics where d.severity.rawValue <= 3 {
            var r = d.range
            if r.length == 0 {
                // Extend zero-width ranges to the word (or one character) so they're visible.
                r = textView.selectionRange(forProposedRange: NSRange(location: min(r.location, max(0, length - 1)), length: 0), granularity: .selectByWord)
                if r.length == 0 && length > 0 { r = NSRange(location: min(d.range.location, length - 1), length: 1) }
            }
            guard NSMaxRange(r) <= length, r.length > 0 else { continue }
            if ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let color = d.severity == .error ? p.error : d.severity == .warning ? p.warning : p.info
            let style = d.severity == .error ? (NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue) : NSUnderlineStyle.single.rawValue
            lm.addTemporaryAttributes([.underlineStyle: style, .underlineColor: color], forCharacterRange: r)
        }
        ruler?.needsDisplay = true
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard let doc = document else { return }
        doc.markEdited()
        workspace?.lsp.didChange(doc)
        scheduleInlayHints()
        ruler?.updateThickness()
        ruler?.needsDisplay = true
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let doc = document else { return }
        let sel = textView.selectedRange()
        let idx = doc.lineIndex
        let line = idx.line(of: sel.location)
        doc.cursorLine = line + 1
        doc.cursorColumn = sel.location - idx.starts[line] + 1
        doc.selectionLength = sel.length
        ruler?.needsDisplay = true
        if textView.window?.firstResponder === textView { workspace?.git.loadBlame(doc.url, line: line + 1) }
        updateBracketMatch()
        scheduleOccurrences()
        unfoldIfCaretInside()
        if completion.isVisible { completion.caretMoved() }
        info.caretMoved()
    }

    /// New text must not inherit inlay-hint spacing from the character before it.
    func textView(_ textView: NSTextView, shouldChangeTypingAttributes old: [String: Any], toAttributes new: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var a = new
        a[.kern] = nil
        a[.zideInlayHint] = nil
        return a
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if completion.isVisible {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)): completion.move(-1); return true
            case #selector(NSResponder.moveDown(_:)): completion.move(1); return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): completion.accept(); return true
            case #selector(NSResponder.cancelOperation(_:)): completion.hide(); return true
            case #selector(NSResponder.pageUp(_:)): completion.move(-8); return true
            case #selector(NSResponder.pageDown(_:)): completion.move(8); return true
            default: break
            }
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { info.hide(); return false }
        return false
    }

    /// Called by the text view after the user types (s is "" for deletions).
    func typed(_ s: String) {
        guard let doc = document else { return }
        if s.isEmpty { if completion.isVisible { completion.refilter() }; return }
        let client = workspace?.lsp.client(of: doc)
        if let ch = s.last {
            let str = String(ch)
            if ch == "/", let t = token(at: max(0, textView.selectedRange().location - 1)), t.kind == .string { completion.trigger(manual: true); return }
            if client?.triggerCharacters.contains(str) == true { completion.trigger(manual: false, char: str); return }
            if client?.signatureTriggers.contains(str) == true { signatureHelp() }
            if ch == ")" { info.hideSignature() }
            if ch.isLetter || ch.isNumber || ch == "_" {
                if completion.isVisible { completion.refilter() } else { completion.trigger(manual: false) }
            } else if completion.isVisible {
                completion.hide()
            }
        }
    }

    // MARK: Brackets & occurrences

    private func updateBracketMatch() {
        let lm = layoutManager
        for r in bracketRanges { lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r) }
        bracketRanges = []
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        guard sel.length == 0, ns.length > 0 else { reapplyOccurrences(); return }
        let pairs: [unichar: (unichar, Int)] = [40: (41, 1), 91: (93, 1), 123: (125, 1), 41: (40, -1), 93: (91, -1), 125: (123, -1)]
        var pos = -1
        for cand in [sel.location - 1, sel.location] where cand >= 0 && cand < ns.length && pairs[ns.character(at: cand)] != nil {
            if let t = token(at: cand), t.kind == .string || t.kind == .comment { continue }
            pos = cand; break
        }
        guard pos >= 0, let (match, dir) = pairs[ns.character(at: pos)] else { reapplyOccurrences(); return }
        let me = ns.character(at: pos)
        var depth = 0, i = pos + dir, steps = 0
        while i >= 0 && i < ns.length && steps < 200_000 {
            let c = ns.character(at: i)
            if c == me || c == match, let t = token(at: i), t.kind == .string || t.kind == .comment { i += dir; steps += 1; continue }
            if c == me { depth += 1 } else if c == match {
                if depth == 0 {
                    bracketRanges = [NSRange(location: pos, length: 1), NSRange(location: i, length: 1)]
                    break
                }
                depth -= 1
            }
            i += dir; steps += 1
        }
        reapplyOccurrences()
        for r in bracketRanges { lm.addTemporaryAttribute(.backgroundColor, value: Theme.current.bracket, forCharacterRange: r) }
    }

    private func scheduleOccurrences() {
        occurrenceTimer?.invalidate()
        occurrenceTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.highlightOccurrences() }
        }
    }

    /// Highlights other uses of the identifier under the caret (LSP documentHighlight, else plain text matches).
    private func highlightOccurrences() {
        guard let doc = document else { return }
        let lm = layoutManager
        for r in occurrenceRanges { lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r) }
        occurrenceRanges = []
        let sel = textView.selectedRange()
        let ns = textView.string as NSString
        let word = wordRange(at: sel.location)
        guard word.length > 1, sel.length == 0 || NSEqualRanges(sel, word) else { updateBracketOnly(); return }
        if let t = token(at: word.location), t.kind == .keyword || t.kind == .string || t.kind == .comment || t.kind == .number { updateBracketOnly(); return }
        let target = ns.substring(with: word)
        if let client = workspace?.lsp.client(of: doc), client.supports("documentHighlightProvider") {
            let version = doc.version
            Task {
                let r = await workspace?.lsp.request("textDocument/documentHighlight", doc, offset: sel.location) as? [JSON]
                guard doc.version == version, let r else { return }
                let idx = doc.lineIndex
                self.setOccurrences(r.compactMap { idx.range($0["range"] as? JSON) })
            }
            return
        }
        guard ns.length < 1_000_000 else { return }
        var found: [NSRange] = []
        var search = NSRange(location: 0, length: ns.length)
        while found.count < 400 {
            let r = ns.range(of: target, options: [.literal], range: search)
            if r.location == NSNotFound { break }
            let before = r.location > 0 ? ns.character(at: r.location - 1) : 32
            let after = NSMaxRange(r) < ns.length ? ns.character(at: NSMaxRange(r)) : 32
            if !Self.isIdent(before) && !Self.isIdent(after) { found.append(r) }
            search = NSRange(location: NSMaxRange(r), length: ns.length - NSMaxRange(r))
        }
        setOccurrences(found.count > 1 ? found : [])
    }

    private func updateBracketOnly() {
        for r in bracketRanges { layoutManager.addTemporaryAttribute(.backgroundColor, value: Theme.current.bracket, forCharacterRange: r) }
    }

    private func setOccurrences(_ ranges: [NSRange]) {
        let lm = layoutManager
        for r in occurrenceRanges { lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r) }
        let len = textView.textStorage?.length ?? 0
        occurrenceRanges = ranges.filter { NSMaxRange($0) <= len }
        reapplyOccurrences()
        updateBracketOnly()
    }

    private func reapplyOccurrences() {
        let color = Theme.isDark ? Palette.hex("373B39") : Palette.hex("EDEBFC")
        for r in occurrenceRanges { layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: r) }
    }

    nonisolated static func isIdent(_ c: unichar) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127
    }

    func wordRange(at loc: Int) -> NSRange {
        let ns = textView.string as NSString
        var a = min(loc, ns.length), b = min(loc, ns.length)
        while a > 0 && Self.isIdent(ns.character(at: a - 1)) { a -= 1 }
        while b < ns.length && Self.isIdent(ns.character(at: b)) { b += 1 }
        return NSRange(location: a, length: b - a)
    }

    // MARK: Editing helpers

    /// Replaces several ranges (sorted back to front) as one undo step.
    func replace(_ edits: [(NSRange, String)]) {
        let tv = textView
        tv.undoManager?.beginUndoGrouping()
        for (r, text) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            guard NSMaxRange(r) <= (tv.textStorage?.length ?? 0), tv.shouldChangeText(in: r, replacementString: text) else { continue }
            tv.textStorage?.replaceCharacters(in: r, with: text)
            tv.didChangeText()
        }
        tv.undoManager?.endUndoGrouping()
    }

    func select(_ range: NSRange, center: Bool = true) {
        let len = textView.textStorage?.length ?? 0
        let r = NSRange(location: min(range.location, len), length: min(range.length, max(0, len - range.location)))
        textView.setSelectedRange(r)
        if center {
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: r.location, length: min(len - r.location, 2000)))
            let glyph = layoutManager.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyph, in: container)
            rect.origin.y += textView.textContainerOrigin.y
            let visible = scrollView.contentView.bounds
            if !visible.insetBy(dx: 0, dy: 40).contains(rect) {
                let y = max(0, rect.midY - visible.height / 3)
                scrollView.contentView.scroll(to: NSPoint(x: max(0, rect.minX - visible.width + 80 > 0 ? rect.minX - 80 : 0), y: y))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }

    // MARK: Language features

    func goToDefinition() {
        guard let doc = document, let ws = workspace else { return }
        let offset = textView.selectedRange().location
        guard ws.lsp.client(of: doc) != nil else { ws.flash(ws.lspHint(for: doc.language, feature: "Go to Definition")); return }
        Task {
            var r = await ws.lsp.request("textDocument/definition", doc, offset: offset)
            if LSP.locations(r).isEmpty { r = await ws.lsp.request("textDocument/declaration", doc, offset: offset) }
            let locs = LSP.locations(r)
            if locs.isEmpty { ws.flash("No definition found"); return }
            ws.pushNavigation()
            if locs.count == 1 { ws.open(locs[0].0, range: locs[0].1) } else {
                ws.showUsages(title: "Definitions of \(self.word(at: offset))", locs)
            }
        }
    }

    func word(at offset: Int) -> String { (textView.string as NSString).substring(with: wordRange(at: offset)) }

    func findUsages() {
        guard let doc = document, let ws = workspace else { return }
        let offset = textView.selectedRange().location
        let w = word(at: offset)
        guard ws.lsp.client(of: doc) != nil else {
            ws.findInFiles(w, wholeWord: true)
            return
        }
        Task {
            let r = await ws.lsp.request("textDocument/references", doc, offset: offset, extra: ["context": ["includeDeclaration": true]])
            let locs = LSP.locations(r)
            if locs.isEmpty { ws.flash("No usages of \(w) found"); return }
            ws.showUsages(title: "Usages of \(w)", locs)
        }
    }

    func renameSymbol() {
        guard let doc = document, let ws = workspace else { return }
        let offset = textView.selectedRange().location
        let old = word(at: offset)
        guard !old.isEmpty else { return }
        guard ws.lsp.client(of: doc)?.supports("renameProvider") == true else { ws.flash(ws.lspHint(for: doc.language, feature: "Rename")); return }
        let alert = NSAlert()
        alert.messageText = "Rename '\(old)'"
        alert.informativeText = "Renames every reference in the project."
        let field = NSTextField(string: old)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Refactor")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let new = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != old else { return }
        Task {
            guard let edit = await ws.lsp.request("textDocument/rename", doc, offset: offset, extra: ["newName": new]) as? JSON else {
                ws.flash("Rename failed"); return
            }
            RefactorPreview.show(ws: ws, edit: edit, title: "Rename ‘\(old)’ to ‘\(new)’")
        }
    }

    func reformat() {
        guard let doc = document, let ws = workspace else { return }
        guard ws.lsp.client(of: doc)?.supports("documentFormattingProvider") == true else {
            ws.flash(ws.lspHint(for: doc.language, feature: "Reformat Code")); return
        }
        let sel = textView.selectedRange()
        let options: JSON = ["tabSize": document?.tabWidth ?? Prefs.shared.tabWidth, "insertSpaces": document?.insertSpaces ?? Prefs.shared.insertSpaces, "trimTrailingWhitespace": true, "insertFinalNewline": true]
        Task {
            let method = sel.length > 0 && ws.lsp.client(of: doc)?.supports("documentRangeFormattingProvider") == true ? "textDocument/rangeFormatting" : "textDocument/formatting"
            var params: JSON = ["options": options]
            if method == "textDocument/rangeFormatting" { params["range"] = doc.lineIndex.lspRange(sel) }
            guard let edits = await ws.lsp.request(method, doc, params: params) as? [JSON] else { ws.flash("Nothing to reformat"); return }
            doc.apply(edits: edits)
            ws.flash("Reformatted \(doc.name)")
        }
    }

    func format(beforeSave completion: @escaping () -> Void) {
        guard let doc = document, let ws = workspace, ws.lsp.client(of: doc)?.supports("documentFormattingProvider") == true else { completion(); return }
        let options: JSON = ["tabSize": document?.tabWidth ?? Prefs.shared.tabWidth, "insertSpaces": document?.insertSpaces ?? Prefs.shared.insertSpaces]
        Task {
            if let edits = await ws.lsp.request("textDocument/formatting", doc, params: ["options": options]) as? [JSON] { doc.apply(edits: edits) }
            completion()
        }
    }

    func hover(at offset: Int, mouse: Bool) {
        guard let doc = document, let ws = workspace else { return }
        let diags = doc.diagnostics.filter { NSLocationInRange(offset, $0.range) || ($0.range.length == 0 && $0.range.location == offset) }
        var text = diags.map { "**\($0.severity == .error ? "Error" : $0.severity == .warning ? "Warning" : "Info")**: \($0.message)" + ($0.source.map { " — _\($0)_" } ?? "") }.joined(separator: "\n\n")
        if mouse, let t = token(at: offset), t.kind == .comment, diags.isEmpty { return }
        guard ws.lsp.client(of: doc)?.supports("hoverProvider") == true else {
            if !text.isEmpty { info.show(markdown: text, at: offset, isHover: mouse) }
            else if !mouse { ws.flash(ws.lspHint(for: doc.language, feature: "Quick Documentation")) }
            return
        }
        Task {
            let r = await ws.lsp.request("textDocument/hover", doc, offset: offset) as? JSON
            let md = LSP.markdown(r?["contents"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !md.isEmpty { text += (text.isEmpty ? "" : "\n\n---\n\n") + md }
            guard !text.isEmpty else { return }
            if mouse, !self.textView.isMouseOverText(offset: offset) { return }
            self.info.show(markdown: text, at: offset, isHover: mouse)
        }
    }

    func signatureHelp() {
        guard let doc = document, let ws = workspace else { return }
        let offset = textView.selectedRange().location
        Task {
            guard let r = await ws.lsp.request("textDocument/signatureHelp", doc, offset: offset) as? JSON,
                  let sigs = r["signatures"] as? [JSON], !sigs.isEmpty else { return }
            let active = min(r["activeSignature"] as? Int ?? 0, sigs.count - 1)
            let sig = sigs[active]
            let label = sig["label"] as? String ?? ""
            var md = "```\n\(label)\n```"
            let doc = LSP.markdown(sig["documentation"])
            if !doc.isEmpty { md += "\n\n" + doc }
            self.info.showSignature(markdown: md, at: offset)
        }
    }

    func showContextActions() {
        guard let doc = document, let ws = workspace else { return }
        guard ws.lsp.client(of: doc)?.supports("codeActionProvider") == true else { ws.flash(ws.lspHint(for: doc.language, feature: "Context Actions")); return }
        let sel = textView.selectedRange()
        let idx = doc.lineIndex
        let lineRange = (textView.string as NSString).lineRange(for: sel)
        let diags: [JSON] = doc.diagnostics.filter { NSIntersectionRange($0.range, lineRange).length > 0 || NSLocationInRange($0.range.location, lineRange) }.map {
            ["range": idx.lspRange($0.range), "message": $0.message, "severity": $0.severity.rawValue]
        }
        Task {
            guard let actions = await ws.lsp.request("textDocument/codeAction", doc, params: ["range": idx.lspRange(sel), "context": ["diagnostics": diags]]) as? [JSON],
                  !actions.isEmpty else { ws.flash("No actions available here"); return }
            let menu = NSMenu()
            for a in actions.prefix(30) {
                let item = NSMenuItem(title: a["title"] as? String ?? "Action", action: #selector(self.runCodeAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = a
                menu.addItem(item)
            }
            let rect = self.textView.firstRect(forCharacterRange: sel, actualRange: nil)
            let windowPoint = self.textView.window?.convertPoint(fromScreen: NSPoint(x: rect.minX, y: rect.minY)) ?? .zero
            menu.popUp(positioning: nil, at: self.textView.convert(windowPoint, from: nil), in: self.textView)
        }
    }

    @objc private func runCodeAction(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? JSON, let doc = document, let ws = workspace else { return }
        if let edit = a["edit"] as? JSON { ws.apply(workspaceEdit: edit) }
        let command = (a["command"] as? JSON) ?? (a["command"] is String ? a : nil)
        if let command, let name = command["command"] as? String, let c = ws.lsp.client(of: doc) {
            c.request("workspace/executeCommand", ["command": name, "arguments": command["arguments"] ?? []]) { _ in }
        } else if a["edit"] == nil, let c = ws.lsp.client(of: doc) {
            // Unresolved action: ask the server to resolve it.
            c.request("codeAction/resolve", a) { result in
                if case .success(let r) = result, let edit = (r as? JSON)?["edit"] as? JSON { ws.apply(workspaceEdit: edit) }
            }
        }
    }

    func showFileStructure() {
        guard let doc = document, let ws = workspace else { return }
        guard ws.lsp.client(of: doc)?.supports("documentSymbolProvider") == true else { ws.flash(ws.lspHint(for: doc.language, feature: "File Structure")); return }
        Task {
            let symbols = await ws.documentSymbols(doc)
            ws.palette.show(title: "File Structure — \(doc.name)", items: symbols.map { s in
                PaletteItem(title: s.name, subtitle: s.detail, icon: SymbolKind.icon(s.kind), indent: s.depth) { [weak self] in
                    ws.pushNavigation()
                    self?.select(s.range)
                    self?.textView.window?.makeFirstResponder(self?.textView)
                }
            })
        }
    }

    func jumpToDiagnostic(forward: Bool) {
        guard let doc = document, !doc.diagnostics.isEmpty else { workspace?.flash("No problems in this file"); return }
        let caret = textView.selectedRange().location
        let sorted = doc.diagnostics.sorted { $0.range.location < $1.range.location }
        let target = forward ? (sorted.first { $0.range.location > caret } ?? sorted.first!) : (sorted.last { $0.range.location < caret } ?? sorted.last!)
        select(target.range)
        hover(at: target.range.location, mouse: false)
    }

    func promptGoToLine() {
        guard let doc = document else { return }
        let alert = NSAlert()
        alert.messageText = "Go to Line:Column"
        let field = NSTextField(string: "\(doc.cursorLine):\(doc.cursorColumn)")
        field.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let parts = field.stringValue.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let line = parts.first else { return }
        workspace?.pushNavigation()
        let off = doc.lineIndex.offset(line: line - 1, character: (parts.count > 1 ? parts[1] : 1) - 1)
        select(NSRange(location: off, length: 0))
    }
}

extension NSTextView {
    /// Whether the mouse is still over the character at `offset` (avoids stale hover popups).
    func isMouseOverText(offset: Int) -> Bool {
        guard let window, let lm = layoutManager, let tc = textContainer else { return false }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let local = NSPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
        var frac: CGFloat = 0
        let g = lm.glyphIndex(for: local, in: tc, fractionOfDistanceThroughGlyph: &frac)
        let idx = lm.characterIndexForGlyph(at: g)
        return abs(idx - offset) < 40
    }
}
