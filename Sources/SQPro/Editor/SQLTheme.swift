import AppKit
import SQCore

/// Editor colours, Xcode-style, with light and dark variants.
enum SQLTheme {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let lineNumberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    static let text = NSColor.textColor
    static let keyword = dynamic(light: 0x9B2393, dark: 0xFC5FA3)
    static let string = dynamic(light: 0xC41A16, dark: 0xFC6A5D)
    static let number = dynamic(light: 0x1C00CF, dark: 0xD0BF69)
    static let comment = dynamic(light: 0x5D6C79, dark: 0x7F8C98)
    static let quotedIdentifier = dynamic(light: 0x326D74, dark: 0x67B7A4)
    static let variable = dynamic(light: 0x6C36A9, dark: 0xA167E6)

    /// Background band behind the statement under the cursor.
    static let currentStatement = NSColor.labelColor.withAlphaComponent(0.07)
    /// Gutter dot on the first line of each statement.
    static let statementMarker = NSColor.systemBlue

    static func color(for kind: SQLTokenKind) -> NSColor? {
        switch kind {
        case .keyword: keyword
        case .string: string
        case .number: number
        case .comment: comment
        case .quotedIdentifier: quotedIdentifier
        case .variable: variable
        default: nil
        }
    }

    private static func dynamic(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        }
    }

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
