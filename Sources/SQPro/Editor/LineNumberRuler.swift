import AppKit

/// Line numbers down the left of the editor, with a blue dot on the first line of each statement.
final class LineNumberRuler: NSRulerView {
    private weak var textView: SQLTextView?

    init(textView: SQLTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        let text = textView.string as NSString
        let statementStarts = Set(textView.statements.map(\.range.lowerBound))
        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let originY = textView.textContainerOrigin.y - visibleRect.minY
        let attributes: [NSAttributedString.Key: Any] = [
            .font: SQLTheme.lineNumberFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        // Number of the first visible line.
        var lineNumber = 1
        text.enumerateSubstrings(in: NSRange(location: 0, length: characterRange.location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            lineNumber += 1
        }

        func drawLabel(_ number: Int, in fragment: NSRect, marked: Bool) {
            let y = fragment.minY + originY
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 14, y: y + (fragment.height - size.height) / 2), withAttributes: attributes)
            if marked {
                SQLTheme.statementMarker.setFill()
                NSBezierPath(ovalIn: NSRect(x: ruleThickness - 10, y: y + fragment.height / 2 - 2.5, width: 5, height: 5)).fill()
            }
        }

        var index = characterRange.location
        while index < NSMaxRange(characterRange) {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layoutManager.glyphIndexForCharacter(at: index)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let marked = statementStarts.contains { $0 >= lineRange.location && $0 < NSMaxRange(lineRange) }
            drawLabel(lineNumber, in: fragment, marked: marked)
            lineNumber += 1
            index = NSMaxRange(lineRange)
        }

        // The empty line after a trailing newline, or the only line of an empty document.
        let extra = layoutManager.extraLineFragmentRect
        if index >= text.length, extra.height > 0 {
            drawLabel(lineNumber, in: extra, marked: false)
        }
    }
}
