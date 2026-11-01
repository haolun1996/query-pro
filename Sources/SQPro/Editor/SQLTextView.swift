import AppKit
import SQCore

/// The SQL text view: TextKit 1 (for invisibles and cheap temporary drawing), syntax colouring,
/// and a full-width band behind the statement under the cursor.
final class SQLTextView: NSTextView {
    /// Statement ranges from the last parse, in UTF-16 offsets.
    private(set) var statements: [SQLStatement] = []
    /// Off for read-only views, where a highlighted "current statement" means nothing.
    var highlightsCurrentStatement = true
    /// The band drawn behind the current statement.
    private var currentStatementRange: NSRange? {
        didSet { if oldValue != currentStatementRange { needsDisplay = true } }
    }

    static func make() -> SQLTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let view = SQLTextView(frame: .zero, textContainer: container)
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        view.font = SQLTheme.font
        view.textColor = SQLTheme.text
        view.backgroundColor = .textBackgroundColor
        view.drawsBackground = true
        view.typingAttributes = [.font: SQLTheme.font, .foregroundColor: SQLTheme.text]
        view.textContainerInset = NSSize(width: 4, height: 6)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        return view
    }

    // MARK: Highlighting

    /// Re-colours the whole text and re-splits statements. Fast enough for scripts of a few thousand lines.
    func rehighlight() {
        guard let storage = textStorage else { return }
        let text = storage.string
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: SQLTheme.font, .foregroundColor: SQLTheme.text], range: full)
        for token in SQL.tokenize(text) {
            guard let color = SQLTheme.color(for: token.kind) else { continue }
            storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: token.range.lowerBound, length: token.range.count))
        }
        storage.endEditing()
        statements = SQL.statements(in: text)
        updateCurrentStatement()
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    func updateCurrentStatement() {
        guard highlightsCurrentStatement else {
            currentStatementRange = nil
            return
        }
        let cursor = selectedRange().location
        guard selectedRange().length == 0, let statement = SQL.statement(at: cursor, in: statements) else {
            currentStatementRange = nil
            return
        }
        currentStatementRange = NSRange(location: statement.range.lowerBound, length: statement.range.count)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let range = currentStatementRange, range.length > 0,
              let layoutManager,
              NSMaxRange(range) <= (textStorage?.length ?? 0)
        else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var band = NSRect.null
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, _, _ in
            band = band.union(lineRect)
        }
        guard !band.isNull else { return }
        band.origin.x = 0
        band.size.width = bounds.width
        band.origin.y += textContainerOrigin.y
        SQLTheme.currentStatement.setFill()
        band.intersection(rect).fill()
    }

    // MARK: Autocomplete

    /// Set for the query editor only; read-only views and the Apply dialog don't complete.
    var completionSource: CompletionSource? {
        didSet {
            if completionSource != nil, completion == nil { completion = CompletionController(textView: self) }
            completion?.source = completionSource
        }
    }
    private var completion: CompletionController?

    #if DEBUG
    var debugCompletionNames: [String] { completion?.debugNames ?? [] }
    #endif
    /// Selection changes made by typing keep the list open; clicks and arrow keys close it.
    private var isChangingText = false

    override func insertText(_ string: Any, replacementRange: NSRange) {
        isChangingText = true
        super.insertText(string, replacementRange: replacementRange)
        isChangingText = false
        guard let completion else { return }
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        // One typed letter, digit, `.` or backtick updates the list; anything else (space, paste, IME commit) closes it.
        if text.count == 1, let scalar = text.unicodeScalars.first,
           scalar == "." || scalar == "`" || scalar == "_" || scalar == "$" || CharacterSet.alphanumerics.contains(scalar) {
            completion.update()
        } else {
            completion.close()
        }
    }

    override func deleteBackward(_ sender: Any?) {
        isChangingText = true
        super.deleteBackward(sender)
        isChangingText = false
        if completion?.isVisible == true { completion?.update() }
    }

    /// Esc and ⌥Esc open the list on demand.
    override func complete(_ sender: Any?) {
        guard let completion else { return super.complete(sender) }
        if completion.isVisible { completion.close() } else { completion.update(manual: true) }
    }

    override func keyDown(with event: NSEvent) {
        // ⌃Space, as in most editors (when the system doesn't use it for switching input sources).
        if completion != nil, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control,
           event.charactersIgnoringModifiers == " " {
            completion?.update(manual: true)
            return
        }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        if let completion, completion.isVisible {
            switch selector {
            case #selector(moveUp(_:)): return completion.moveSelection(by: -1)
            case #selector(moveDown(_:)): return completion.moveSelection(by: 1)
            case #selector(scrollPageUp(_:)), #selector(pageUp(_:)): return completion.moveSelection(by: -9)
            case #selector(scrollPageDown(_:)), #selector(pageDown(_:)): return completion.moveSelection(by: 9)
            case #selector(insertNewline(_:)), #selector(insertTab(_:)):
                if completion.accept() { return }
            case #selector(cancelOperation(_:)): return completion.close()
            case #selector(deleteBackward(_:)): break
            default: completion.close()
            }
        }
        super.doCommand(by: selector)
    }

    /// Called by the editor's delegate.
    func selectionDidChange() {
        if !isChangingText { completion?.close() }
    }

    override func resignFirstResponder() -> Bool {
        completion?.close()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { completion?.close() }
        super.viewWillMove(toWindow: newWindow)
    }

    /// One undoable change that doesn't reopen the list.
    func insertCompletion(_ text: String, replacing range: NSRange) {
        isChangingText = true
        super.insertText(text, replacementRange: range)
        isChangingText = false
    }

    // MARK: Editing helpers

    /// Replaces the whole text as one undoable change.
    func replaceAll(with text: String) {
        let full = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: full, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: full, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: 0, length: 0))
    }

    /// Inserts at the cursor (replacing any selection) as one undoable change.
    func insertAtCursor(_ text: String) {
        window?.makeFirstResponder(self)
        insertText(text, replacementRange: selectedRange())
    }

    func showFindBar() {
        window?.makeFirstResponder(self)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        performTextFinderAction(item)
    }

    /// Toggles soft wrapping. Without wrapping the text scrolls sideways.
    func setWrapsLines(_ wraps: Bool) {
        guard let textContainer, let scrollView = enclosingScrollView else { return }
        if wraps {
            isHorizontallyResizable = false
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
            frame.size.width = scrollView.contentSize.width
            scrollView.hasHorizontalScroller = false
        } else {
            textContainer.widthTracksTextView = false
            textContainer.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            isHorizontallyResizable = true
            scrollView.hasHorizontalScroller = true
        }
        layoutManager?.ensureLayout(for: textContainer)
        needsDisplay = true
    }

    func setShowsInvisibles(_ shows: Bool) {
        guard let layoutManager, layoutManager.showsInvisibleCharacters != shows else { return }
        layoutManager.showsInvisibleCharacters = shows
        layoutManager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage?.length ?? 0))
    }
}
