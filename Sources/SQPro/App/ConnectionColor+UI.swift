import AppKit
import SwiftUI
import SQCore

extension ConnectionColor {
    var color: Color? {
        switch self {
        case .none: nil
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        }
    }

    var title: String {
        self == .none ? "None" : rawValue.capitalized
    }

    /// A coloured dot for menus. Menus draw SF Symbols as one-colour templates and ignore
    /// `foregroundStyle`, so the colour has to be baked into a non-template image.
    var swatch: Image {
        let symbol = self == .none ? "circle.dashed" : "circle.fill"
        let tint = color.map(NSColor.init) ?? .secondaryLabelColor
        let configuration = NSImage.SymbolConfiguration(paletteColors: [tint])
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = false
        return Image(nsImage: image)
    }
}
