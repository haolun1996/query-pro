import Foundation
import Observation
import SQCore

/// One result set and how it is being viewed: filter, sort and selected rows.
@Observable
final class ResultTab: Identifiable {
    let id = UUID()
    let title: String
    let result: QueryResult
    /// The `LIMIT` SQ Pro added, if any.
    let appliedLimit: Int?
    let executedAt = Date()

    /// Filter Rows text: keeps rows where any value contains it (case-insensitive).
    var filter = "" {
        didSet { if filter != oldValue { refresh() } }
    }
    private(set) var sortColumn: Int?
    private(set) var sortAscending = true

    /// Indices into `result.rows`, after filtering and sorting. This is what the grid shows.
    private(set) var visibleRows: [Int]
    /// Bumped whenever `visibleRows` changes, so the grid knows to reload.
    private(set) var version = 0
    /// Selected positions in `visibleRows`.
    var selectedRows = IndexSet()

    init(title: String, result: QueryResult, appliedLimit: Int?) {
        self.title = title
        self.result = result
        self.appliedLimit = appliedLimit
        self.visibleRows = Array(result.rows.indices)
    }

    func value(atVisibleRow row: Int, column: Int) -> String? {
        result.rows[visibleRows[row]][column]
    }

    func sort(by column: Int?, ascending: Bool) {
        sortColumn = column
        sortAscending = ascending
        refresh()
    }

    /// `"3 rows"`, `"1000 rows (limited)"`, `"2 of 3 rows"` while filtering.
    var countText: String {
        let total = result.rows.count
        var text = visibleRows.count == total ? "\(total) row\(total == 1 ? "" : "s")" : "\(visibleRows.count) of \(total) rows"
        if isLimited { text += " (limited)" }
        return text
    }

    /// The added `LIMIT` was reached, so there may be more rows on the server.
    var isLimited: Bool {
        guard let appliedLimit else { return false }
        return result.rows.count >= appliedLimit
    }

    private func refresh() {
        var rows = Array(result.rows.indices)
        let needle = filter.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            rows = rows.filter { index in
                result.rows[index].contains { $0?.localizedCaseInsensitiveContains(needle) == true }
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
        visibleRows = rows
        selectedRows = IndexSet()
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
        ["TINY", "SHORT", "LONG", "LONGLONG", "INT24", "FLOAT", "DOUBLE", "DECIMAL", "NEWDECIMAL", "YEAR"].contains(typeName)
    }
}
