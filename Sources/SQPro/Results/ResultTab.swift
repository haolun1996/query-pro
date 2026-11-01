import Foundation
import Observation
import SQCore

/// One result set and how it is being viewed: filter, sort, selection, and pending edits.
@Observable
final class ResultTab: Identifiable {
    /// Which table edits go to, and how rows are identified there.
    struct EditTarget {
        let schema: String
        let table: String
        /// Result column indices that make up the primary key.
        let primaryKey: [Int]
        /// Result columns that come straight from the table (not expressions or joins).
        let editableColumns: Set<Int>
        /// `false` when the server's sql_mode has NO_BACKSLASH_ESCAPES.
        var backslashEscapes = true
    }

    enum RowState {
        case normal, inserted, deleted
    }

    typealias Edits = RowEdits

    let id = UUID()
    let title: String
    let result: QueryResult
    /// The `LIMIT` Querywell added, if any.
    let appliedLimit: Int?
    let executedAt = Date()

    /// Filter Rows text: keeps rows where any value contains it (case-insensitive).
    var filter = "" {
        didSet { if filter != oldValue { refresh() } }
    }
    private(set) var sortColumn: Int?
    private(set) var sortAscending = true

    /// Row indices after filtering and sorting; this is what the grid shows. Indices at or past
    /// `result.rows.count` are inserted rows, always listed last.
    private(set) var visibleRows: [Int]
    /// Bumped whenever the grid must reload.
    private(set) var version = 0
    /// Selected positions in `visibleRows`.
    var selectedRows = IndexSet()

    /// Set once we know the result maps onto one table with a primary key.
    var editTarget: EditTarget?
    /// Why the grid is read-only, shown next to the edit buttons.
    var readOnlyReason: String? = "Checking whether this result can be edited…"
    private(set) var edits = Edits()
    /// Asks the grid to start editing this cell (visible row, column), e.g. after inserting a row.
    var pendingEdit: (row: Int, column: Int)?
    /// The window's undo manager, set by the grid, so ⌘Z undoes edits.
    @ObservationIgnored weak var undoManager: UndoManager?

    init(title: String, result: QueryResult, appliedLimit: Int?) {
        self.title = title
        self.result = result
        self.appliedLimit = appliedLimit
        self.visibleRows = Array(result.rows.indices)
    }

    var isEditable: Bool { editTarget != nil }
    var hasChanges: Bool { !edits.isEmpty }

    // MARK: Reading

    func value(atVisibleRow row: Int, column: Int) -> String? {
        let index = visibleRows[row]
        if index >= result.rows.count {
            return edits.inserted[index - result.rows.count][column] ?? nil
        }
        if let updated = edits.updates[index]?[column] { return updated }
        return result.rows[index][column]
    }

    func rowState(atVisibleRow row: Int) -> RowState {
        let index = visibleRows[row]
        if index >= result.rows.count { return .inserted }
        return edits.deleted.contains(index) ? .deleted : .normal
    }

    /// Changed by the user and not applied yet.
    func isEdited(atVisibleRow row: Int, column: Int) -> Bool {
        let index = visibleRows[row]
        if index >= result.rows.count { return edits.inserted[index - result.rows.count][column] != nil }
        return edits.updates[index]?[column] != nil
    }

    func canEdit(column: Int) -> Bool {
        editTarget?.editableColumns.contains(column) == true
    }

    /// A new row's column the user hasn't set: the INSERT leaves it to the table's default.
    func isDefault(atVisibleRow row: Int, column: Int) -> Bool {
        let index = visibleRows[row]
        guard index >= result.rows.count else { return false }
        return edits.inserted[index - result.rows.count][column] == nil
    }

    /// Where typing starts in a new row: the first editable column that MySQL doesn't fill in itself.
    var firstEditableColumn: Int? {
        guard let columns = editTarget?.editableColumns.sorted() else { return nil }
        return columns.first { !result.columns[$0].isAutoIncrement } ?? columns.first
    }

    // MARK: Editing

    /// Replaces all pending edits at once; used for undo.
    func restore(_ snapshot: Edits) {
        edits = snapshot
        refresh(keepSelection: true)
    }

    func setValue(_ value: String?, atVisibleRow row: Int, column: Int) {
        guard canEdit(column: column), row < visibleRows.count else { return }
        guard value != self.value(atVisibleRow: row, column: column) || isDefault(atVisibleRow: row, column: column) else { return }
        recordUndo("Edit Field")
        let index = visibleRows[row]
        if index >= result.rows.count {
            edits.inserted[index - result.rows.count][column] = .some(value)
        } else if result.rows[index][column] == value {
            // Back to the original value: no longer a change.
            edits.updates[index]?[column] = nil
            if edits.updates[index]?.isEmpty == true { edits.updates[index] = nil }
        } else {
            edits.updates[index, default: [:]][column] = .some(value)
        }
        version += 1
    }

    /// Adds an empty row at the end and returns its visible position.
    @discardableResult
    func insertRow() -> Int? {
        guard isEditable else { return nil }
        recordUndo("Add Row")
        edits.inserted.append([:])
        refresh(keepSelection: false)
        let row = visibleRows.count - 1
        selectedRows = IndexSet(integer: row)
        return row
    }

    /// Marks rows for deletion. New rows that were never saved are simply dropped.
    func deleteRows(_ rows: IndexSet) {
        guard isEditable, !rows.isEmpty else { return }
        recordUndo("Delete Rows")
        var droppedInserts = IndexSet()
        for row in rows where row < visibleRows.count {
            let index = visibleRows[row]
            if index >= result.rows.count {
                droppedInserts.insert(index - result.rows.count)
            } else {
                edits.deleted.insert(index)
            }
        }
        edits.inserted.remove(atOffsets: droppedInserts)
        refresh(keepSelection: droppedInserts.isEmpty)
    }

    func revert() {
        guard hasChanges else { return }
        recordUndo("Revert")
        edits = Edits()
        refresh(keepSelection: false)
    }

    /// Registers an undo step back to the current edits. Undoing registers the matching redo.
    private func recordUndo(_ name: String) {
        guard let undoManager else { return }
        let before = edits
        undoManager.registerUndo(withTarget: self) { tab in
            tab.recordUndo(name)
            tab.restore(before)
        }
        undoManager.setActionName(name)
    }

    /// The SQL for the pending edits, shown in the Apply dialog.
    func changeScript() -> String {
        guard let target = editTarget else { return "" }
        return ChangeScript.build(
            schema: target.schema, table: target.table, primaryKey: target.primaryKey,
            columns: result.columns, rows: result.rows, edits: edits, backslashEscapes: target.backslashEscapes
        )
    }

    // MARK: Export

    /// The INSERT target: the edited table, else the one table the columns come from, else a placeholder to rename.
    var exportTable: String {
        if let target = editTarget { return "\(SQL.quoteIdentifier(target.schema)).\(SQL.quoteIdentifier(target.table))" }
        let sources = Set(result.columns.filter { !$0.table.isEmpty }.map { [$0.schema, $0.table] })
        if sources.count == 1, let source = sources.first {
            return source[0].isEmpty ? SQL.quoteIdentifier(source[1]) : "\(SQL.quoteIdentifier(source[0])).\(SQL.quoteIdentifier(source[1]))"
        }
        return "`table_name`"
    }

    /// A file name without extension, e.g. `admins` for "admins 2".
    var exportFileName: String {
        let sources = Set(result.columns.map(\.table).filter { !$0.isEmpty })
        return sources.count == 1 ? sources.first! : title
    }

    /// The rows as loaded, in the grid's filter and sort; unsaved edits aren't part of the file.
    func export(_ format: ResultExport.Format) -> String {
        let rows = visibleRows.filter { $0 < result.rows.count }.map { result.rows[$0] }
        return export(format, rows: rows)
    }

    /// Selected grid rows as shown, edits included, like Copy Row.
    func export(_ format: ResultExport.Format, visibleRows rows: IndexSet) -> String {
        let values = rows.filter { $0 < visibleRows.count }.map { row in
            result.columns.indices.map { value(atVisibleRow: row, column: $0) }
        }
        return export(format, rows: values)
    }

    private func export(_ format: ResultExport.Format, rows: [[String?]]) -> String {
        ResultExport.export(format, columns: result.columns, rows: rows, table: exportTable, backslashEscapes: editTarget?.backslashEscapes ?? true)
    }

    // MARK: Viewing

    func sort(by column: Int?, ascending: Bool) {
        sortColumn = column
        sortAscending = ascending
        refresh(keepSelection: false)
    }

    /// `"3 rows"`, `"1000 rows (limited)"`, `"2 of 3 rows"` while filtering.
    var countText: String {
        let total = result.rows.count
        let shown = visibleRows.filter { $0 < total }.count
        var text = shown == total ? "\(total) row\(total == 1 ? "" : "s")" : "\(shown) of \(total) rows"
        if isLimited { text += " (limited)" }
        return text
    }

    /// The added `LIMIT` was reached, so there may be more rows on the server.
    var isLimited: Bool {
        guard let appliedLimit else { return false }
        return result.rows.count >= appliedLimit
    }

    private func refresh(keepSelection: Bool = false) {
        var rows = Array(result.rows.indices)
        let needle = filter.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            rows = rows.filter { index in
                (0..<result.columns.count).contains { column in
                    let value = edits.updates[index]?[column] ?? result.rows[index][column]
                    return value?.localizedCaseInsensitiveContains(needle) == true
                }
            }
        }
        if let column = sortColumn, column < result.columns.count {
            let numeric = Self.isNumeric(result.columns[column].typeName)
            let all = result.rows
            rows.sort { a, b in
                let ordered = Self.less(all[a][column], all[b][column], numeric: numeric)
                let reversed = Self.less(all[b][column], all[a][column], numeric: numeric)
                if !ordered && !reversed { return a < b }
                return sortAscending ? ordered : reversed
            }
        }
        rows += edits.inserted.indices.map { result.rows.count + $0 }
        visibleRows = rows
        if !keepSelection { selectedRows = IndexSet() }
        selectedRows = selectedRows.filteredIndexSet { $0 < rows.count }
        version += 1
    }

    /// NULL sorts first, then numbers by value or text in Finder order.
    private static func less(_ a: String?, _ b: String?, numeric: Bool) -> Bool {
        switch (a, b) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case let (a?, b?):
            if numeric, let x = Double(a), let y = Double(b) { return x < y }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    static func isNumeric(_ typeName: String) -> Bool {
        ChangeScript.isNumeric(typeName)
    }
}
