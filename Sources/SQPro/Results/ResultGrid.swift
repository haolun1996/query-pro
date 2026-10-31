import AppKit
import SwiftUI
import SQCore

/// The result grid: a view-based `NSTableView`, so tens of thousands of rows scroll smoothly.
/// Click a header to sort, ⌘C copies the selected rows as tab-separated text.
/// When the result is editable: double-click a cell to edit, Tab moves along the row, Esc cancels,
/// Delete marks the selected rows for deletion, ⌘Z undoes.
struct ResultGrid: NSViewRepresentable {
    let resultTab: ResultTab
    /// Multi-line values are edited in the Form Editor instead of the one-line cell.
    let editInForm: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(resultTab: resultTab, editInForm: editInForm)
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
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.doubleClicked)
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
        DispatchQueue.main.async { resultTab.undoManager = tableView.undoManager }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let tableView = coordinator.tableView else { return }
        if coordinator.version != resultTab.version {
            coordinator.version = resultTab.version
            if coordinator.editing == nil { tableView.reloadData() }
        }
        if tableView.selectedRowIndexes != resultTab.selectedRows {
            coordinator.isApplyingSelection = true
            tableView.selectRowIndexes(resultTab.selectedRows, byExtendingSelection: false)
            if let first = resultTab.selectedRows.first { tableView.scrollRowToVisible(first) }
            coordinator.isApplyingSelection = false
        }
        if let pending = resultTab.pendingEdit {
            DispatchQueue.main.async {
                resultTab.pendingEdit = nil
                coordinator.beginEditing(row: pending.row, column: pending.column)
            }
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

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        struct Editing {
            let row: Int
            let column: Int
            let wasNull: Bool
            var changed = false
        }

        let resultTab: ResultTab
        let editInForm: (Int) -> Void
        weak var tableView: NSTableView?
        var version = 0
        var isApplyingSelection = false
        var editing: Editing?

        init(resultTab: ResultTab, editInForm: @escaping (Int) -> Void) {
            self.resultTab = resultTab
            self.editInForm = editInForm
        }

        // MARK: Data

        func numberOfRows(in tableView: NSTableView) -> Int {
            resultTab.visibleRows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Int(tableColumn.identifier.rawValue) else { return nil }
            let cell = tableView.makeView(withIdentifier: GridCell.identifier, owner: nil) as? GridCell ?? GridCell()
            cell.configure(
                value: resultTab.value(atVisibleRow: row, column: column),
                isDefault: resultTab.isDefault(atVisibleRow: row, column: column),
                isEdited: resultTab.isEdited(atVisibleRow: row, column: column),
                isDeleted: resultTab.rowState(atVisibleRow: row) == .deleted
            )
            cell.editField.delegate = self
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = GridRowView()
            switch resultTab.rowState(atVisibleRow: row) {
            case .normal: rowView.tint = nil
            case .inserted: rowView.tint = NSColor.systemGreen.withAlphaComponent(0.16)
            case .deleted: rowView.tint = NSColor.systemRed.withAlphaComponent(0.16)
            }
            return rowView
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

        // MARK: Editing

        @objc func doubleClicked() {
            guard let tableView, tableView.clickedRow >= 0, tableView.clickedColumn >= 0,
                  let column = Int(tableView.tableColumns[tableView.clickedColumn].identifier.rawValue)
            else { return }
            beginEditing(row: tableView.clickedRow, column: column)
        }

        /// Starts in-cell editing of a result column (not a table column position).
        func beginEditing(row: Int, column: Int) {
            guard let tableView, row < resultTab.visibleRows.count, resultTab.canEdit(column: column),
                  resultTab.rowState(atVisibleRow: row) != .deleted
            else {
                if !resultTab.isEditable { NSSound.beep() }
                return
            }
            let value = resultTab.value(atVisibleRow: row, column: column)
            if let value, value.contains(where: \.isNewline) || value.count > 500 {
                editInForm(row)
                return
            }
            let position = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("\(column)"))
            guard position >= 0 else { return }
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
            tableView.scrollColumnToVisible(position)
            guard let cell = tableView.view(atColumn: position, row: row, makeIfNecessary: true) as? GridCell else { return }
            editing = Editing(row: row, column: column, wasNull: value == nil)
            cell.beginEditing(value ?? "")
            tableView.window?.makeFirstResponder(cell.editField)
            cell.editField.currentEditor()?.selectAll(nil)
        }

        func controlTextDidChange(_ obj: Notification) {
            editing?.changed = true
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                finishEditing(commit: false)
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard editing != nil else { return }
            let movement = (obj.userInfo?["NSTextMovement"] as? Int).flatMap(NSTextMovement.init(rawValue:))
            let next = finishEditing(commit: true)
            guard let next else { return }
            switch movement {
            case .tab: moveEditing(from: next, by: 1)
            case .backtab: moveEditing(from: next, by: -1)
            default: break
            }
        }

        /// Ends editing and returns the cell that was being edited.
        @discardableResult
        private func finishEditing(commit: Bool) -> Editing? {
            guard let current = editing, let tableView else { return nil }
            editing = nil
            let position = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("\(current.column)"))
            let cell = position >= 0 ? tableView.view(atColumn: position, row: current.row, makeIfNecessary: false) as? GridCell : nil
            let text = cell?.editField.stringValue ?? ""
            cell?.endEditing()
            // Leaving a NULL cell without typing keeps it NULL rather than turning it into ''.
            if commit, !(current.wasNull && !current.changed) {
                resultTab.setValue(text, atVisibleRow: current.row, column: current.column)
            }
            tableView.reloadData()
            tableView.window?.makeFirstResponder(tableView)
            return current
        }

        /// Tab / Shift-Tab: the next editable column in on-screen order.
        private func moveEditing(from current: Editing, by step: Int) {
            guard let tableView else { return }
            let order = tableView.tableColumns.compactMap { Int($0.identifier.rawValue) }.filter(resultTab.canEdit(column:))
            guard let index = order.firstIndex(of: current.column) else { return }
            let target = index + step
            guard order.indices.contains(target) else { return }
            DispatchQueue.main.async { self.beginEditing(row: current.row, column: order[target]) }
        }

        func deleteSelectedRows() {
            guard let tableView, resultTab.isEditable, !tableView.selectedRowIndexes.isEmpty else { return }
            resultTab.deleteRows(tableView.selectedRowIndexes)
        }

        // MARK: Menu

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = true
            menu.addItem(withTitle: "Edit Field", action: #selector(editField), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Set Field to NULL", action: #selector(setFieldToNull), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Add Row", action: #selector(addRow), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Delete Row(s)", action: #selector(deleteRows), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Copy Field", action: #selector(copyField), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Copy Row", action: #selector(copyRows), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Copy Rows with Column Names", action: #selector(copyRowsWithHeader), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Copy Column Name", action: #selector(copyColumnName), keyEquivalent: "").target = self
            return menu
        }

        @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
            switch item.action {
            case #selector(editField), #selector(setFieldToNull):
                guard let column = clickedColumn, let tableView, tableView.clickedRow >= 0 else { return false }
                return resultTab.canEdit(column: column) && resultTab.rowState(atVisibleRow: tableView.clickedRow) != .deleted
            case #selector(addRow):
                return resultTab.isEditable
            case #selector(deleteRows):
                return resultTab.isEditable && !targetRows.isEmpty
            default:
                return true
            }
        }

        /// The result column under the right-click.
        private var clickedColumn: Int? {
            guard let tableView, tableView.clickedColumn >= 0 else { return nil }
            return Int(tableView.tableColumns[tableView.clickedColumn].identifier.rawValue)
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

        @objc func editField() {
            guard let tableView, let column = clickedColumn else { return }
            beginEditing(row: tableView.clickedRow, column: column)
        }

        @objc func setFieldToNull() {
            guard let tableView, let column = clickedColumn, tableView.clickedRow >= 0 else { return }
            resultTab.setValue(nil, atVisibleRow: tableView.clickedRow, column: column)
        }

        @objc func addRow() {
            guard let row = resultTab.insertRow(), let first = resultTab.firstEditableColumn else { return }
            resultTab.pendingEdit = (row, first)
        }

        @objc func deleteRows() {
            resultTab.deleteRows(targetRows)
        }

        @objc func copyField() {
            guard let tableView, tableView.clickedRow >= 0, let column = clickedColumn else { return }
            write(resultTab.value(atVisibleRow: tableView.clickedRow, column: column) ?? "NULL")
        }

        @objc func copyRows() {
            write(text(for: targetRows, header: false))
        }

        @objc func copyRowsWithHeader() {
            write(text(for: targetRows, header: true))
        }

        @objc func copyColumnName() {
            guard let column = clickedColumn else { return }
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

/// Adds ⌘C (copy rows) and Delete (mark rows for deletion) to the table.
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

    override func keyDown(with event: NSEvent) {
        // 51 = Delete (backspace), 117 = Forward Delete.
        if event.keyCode == 51 || event.keyCode == 117, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            coordinator?.deleteSelectedRows()
            return
        }
        super.keyDown(with: event)
    }
}

/// Tints the whole row: green for new rows, red for rows marked for deletion.
final class GridRowView: NSTableRowView {
    var tint: NSColor?

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let tint else { return }
        tint.setFill()
        bounds.fill()
    }
}

/// One grid cell: the value on one line, a NULL badge, or an editable field while editing.
final class GridCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("GridCell")
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private static let editedTint = NSColor.systemBlue.withAlphaComponent(0.32)

    private let label = NSTextField(labelWithString: "")
    private let badge = NullBadge()
    /// Separate from the label so a display value (↵, …) is never written back by accident.
    let editField = NSTextField(string: "")
    private var isEdited = false

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.font = Self.font
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        editField.font = Self.font
        editField.isBordered = false
        editField.focusRingType = .none
        editField.drawsBackground = true
        editField.backgroundColor = .textBackgroundColor
        editField.usesSingleLineMode = true
        editField.cell?.isScrollable = true
        editField.isHidden = true
        for view in [label, badge, editField] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            editField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            editField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            editField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// `isDefault`: a new row's column the user hasn't touched, which the INSERT leaves to the table default.
    func configure(value: String?, isDefault: Bool, isEdited: Bool, isDeleted: Bool) {
        endEditing()
        self.isEdited = isEdited
        needsDisplay = true
        if isDefault {
            label.attributedStringValue = NSAttributedString(string: "DEFAULT", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ])
            label.isHidden = false
            badge.isHidden = true
            toolTip = "Left to the column's default value"
        } else if let value {
            var attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.labelColor]
            if isDeleted { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            label.attributedStringValue = NSAttributedString(string: Self.displayText(value), attributes: attributes)
            label.isHidden = false
            badge.isHidden = true
            toolTip = value.count > 40 ? String(value.prefix(2000)) : nil
        } else {
            label.isHidden = true
            badge.isHidden = false
            toolTip = nil
        }
    }

    func beginEditing(_ value: String) {
        editField.stringValue = value
        editField.isHidden = false
        label.isHidden = true
        badge.isHidden = true
    }

    func endEditing() {
        editField.isHidden = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isEdited {
            Self.editedTint.setFill()
            bounds.fill()
        }
        super.draw(dirtyRect)
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
