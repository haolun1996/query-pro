import AppKit
import SwiftUI
import SQCore

/// The result grid: a view-based `NSTableView`, so tens of thousands of rows scroll smoothly.
/// Click a header to sort, ⌘C copies the selected rows as tab-separated text.
struct ResultGrid: NSViewRepresentable {
    let resultTab: ResultTab

    func makeCoordinator() -> Coordinator {
        Coordinator(resultTab: resultTab)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = GridTableView()
        tableView.style = .plain
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.coordinator = context.coordinator
        tableView.menu = context.coordinator.makeMenu()

        let font = GridCell.font
        for (index, column) in resultTab.result.columns.enumerated() {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
            tableColumn.title = column.name
            tableColumn.headerToolTip = "\(column.name) · \(column.typeName)\(column.isPrimaryKey ? " · PRIMARY KEY" : "")"
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: "\(index)", ascending: true)
            tableColumn.width = Self.idealWidth(for: index, in: resultTab, font: font)
            tableColumn.minWidth = 40
            tableView.addTableColumn(tableColumn)
        }

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        context.coordinator.tableView = tableView
        context.coordinator.version = resultTab.version
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let tableView = coordinator.tableView else { return }
        if coordinator.version != resultTab.version {
            coordinator.version = resultTab.version
            tableView.reloadData()
        }
        if tableView.selectedRowIndexes != resultTab.selectedRows {
            coordinator.isApplyingSelection = true
            tableView.selectRowIndexes(resultTab.selectedRows, byExtendingSelection: false)
            if let first = resultTab.selectedRows.first { tableView.scrollRowToVisible(first) }
            coordinator.isApplyingSelection = false
        }
    }

    /// Fits the header and the first couple of hundred values, capped so one long column can't take over.
    private static func idealWidth(for column: Int, in resultTab: ResultTab, font: NSFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let header = (resultTab.result.columns[column].name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width
        var widest = header + 24
        for row in resultTab.result.rows.prefix(200) {
            guard let value = row[column] else { widest = max(widest, 50); continue }
            let shown = GridCell.displayText(value)
            widest = max(widest, (shown as NSString).size(withAttributes: attributes).width + 16)
            if widest >= 320 { break }
        }
        return min(max(widest, 50), 320)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let resultTab: ResultTab
        weak var tableView: NSTableView?
        var version = 0
        var isApplyingSelection = false

        init(resultTab: ResultTab) {
            self.resultTab = resultTab
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            resultTab.visibleRows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Int(tableColumn.identifier.rawValue) else { return nil }
            let cell = tableView.makeView(withIdentifier: GridCell.identifier, owner: nil) as? GridCell ?? GridCell()
            let value = resultTab.value(atVisibleRow: row, column: column)
            cell.configure(value: value)
            return cell
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else {
                resultTab.sort(by: nil, ascending: true)
                return
            }
            resultTab.sort(by: Int(key), ascending: descriptor.ascending)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let tableView else { return }
            resultTab.selectedRows = tableView.selectedRowIndexes
        }

        // MARK: Copying

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.addItem(withTitle: "Copy Field", action: #selector(copyField), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Copy Row", action: #selector(copyRows), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Copy Rows with Column Names", action: #selector(copyRowsWithHeader), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Copy Column Name", action: #selector(copyColumnName), keyEquivalent: "").target = self
            return menu
        }

        /// The rows a context-menu action applies to: the selection if the click was inside it, else the clicked row.
        private var targetRows: IndexSet {
            guard let tableView else { return [] }
            let clicked = tableView.clickedRow
            if clicked >= 0, !tableView.selectedRowIndexes.contains(clicked) { return [clicked] }
            return tableView.selectedRowIndexes
        }

        /// Columns in their on-screen order (the user may have dragged them around).
        private var orderedColumns: [Int] {
            tableView?.tableColumns.compactMap { Int($0.identifier.rawValue) } ?? []
        }

        @objc func copyField() {
            guard let tableView, tableView.clickedRow >= 0, tableView.clickedColumn >= 0,
                  let column = Int(tableView.tableColumns[tableView.clickedColumn].identifier.rawValue)
            else { return }
            write(resultTab.value(atVisibleRow: tableView.clickedRow, column: column) ?? "NULL")
        }

        @objc func copyRows() {
            write(text(for: targetRows, header: false))
        }

        @objc func copyRowsWithHeader() {
            write(text(for: targetRows, header: true))
        }

        @objc func copyColumnName() {
            guard let tableView, tableView.clickedColumn >= 0,
                  let column = Int(tableView.tableColumns[tableView.clickedColumn].identifier.rawValue)
            else { return }
            write(resultTab.result.columns[column].name)
        }

        /// Tab-separated, one line per row, NULL written as `NULL`.
        func text(for rows: IndexSet, header: Bool) -> String {
            let columns = orderedColumns
            var lines: [String] = []
            if header { lines.append(columns.map { resultTab.result.columns[$0].name }.joined(separator: "\t")) }
            for row in rows where row < resultTab.visibleRows.count {
                lines.append(columns.map { resultTab.value(atVisibleRow: row, column: $0) ?? "NULL" }.joined(separator: "\t"))
            }
            return lines.joined(separator: "\n")
        }

        private func write(_ text: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

/// Adds ⌘C (Edit › Copy) to the table: copies the selected rows.
final class GridTableView: NSTableView {
    weak var coordinator: ResultGrid.Coordinator?

    @objc func copy(_ sender: Any?) {
        guard let coordinator, !selectedRowIndexes.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(coordinator.text(for: selectedRowIndexes, header: false), forType: .string)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selectedRowIndexes.isEmpty }
        return super.validateUserInterfaceItem(item)
    }
}

/// One grid cell: the value on one line, or a small NULL badge.
final class GridCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("GridCell")
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    private let label = NSTextField(labelWithString: "")
    private let badge = NullBadge()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.font = Self.font
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(badge)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(value: String?) {
        if let value {
            label.stringValue = Self.displayText(value)
            label.isHidden = false
            badge.isHidden = true
            toolTip = value.count > 40 ? String(value.prefix(2000)) : nil
        } else {
            label.isHidden = true
            badge.isHidden = false
            toolTip = nil
        }
    }

    /// One line, at most 500 characters: newlines shown as ↵ so multi-line text stays readable.
    static func displayText(_ value: String) -> String {
        let short = value.count > 500 ? String(value.prefix(500)) + "…" : value
        return short.replacingOccurrences(of: "\r\n", with: "↵").replacingOccurrences(of: "\n", with: "↵")
    }
}

/// The grey "NULL" pill.
final class NullBadge: NSView {
    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]
    private static let text = "NULL" as NSString

    override var intrinsicContentSize: NSSize {
        let size = Self.text.size(withAttributes: Self.attributes)
        return NSSize(width: ceil(size.width) + 8, height: 13)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        let size = Self.text.size(withAttributes: Self.attributes)
        Self.text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: Self.attributes)
    }
}
