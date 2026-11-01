import AppKit
import UniformTypeIdentifiers
import SQCore

/// Save panel and clipboard for result exports.
enum ResultFiles {
    static func export(_ result: ResultTab, as format: ResultExport.Format) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.nameFieldStringValue = "\(result.exportFileName).\(format.fileExtension)"
        panel.message = "Exports \(result.countText) as \(format.title). Unsaved edits aren't included."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try result.export(format).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
