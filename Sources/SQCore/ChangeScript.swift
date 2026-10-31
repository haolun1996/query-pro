import Foundation

/// Pending grid edits, kept as overlays on the original rows.
public struct RowEdits: Sendable, Equatable {
    /// Original row index → column → new value (`nil` = NULL).
    public var updates: [Int: [Int: String?]] = [:]
    /// Original row indices marked for deletion.
    public var deleted: Set<Int> = []
    /// New rows: column → value. Columns never set are left out of the INSERT, so table defaults apply.
    public var inserted: [[Int: String?]] = []

    public init() {}

    public var isEmpty: Bool { updates.isEmpty && deleted.isEmpty && inserted.isEmpty }
}

/// Turns grid edits into SQL: DELETEs, then UPDATEs, then INSERTs, one statement per line.
public enum ChangeScript {
    public static func build(
        schema: String,
        table: String,
        primaryKey: [Int],
        columns: [ColumnInfo],
        rows: [[String?]],
        edits: RowEdits,
        backslashEscapes: Bool = true
    ) -> String {
        let target = "\(SQL.quoteIdentifier(schema)).\(SQL.quoteIdentifier(table))"
        func name(_ column: Int) -> String { SQL.quoteIdentifier(columns[column].originalName) }
        func value(_ text: String?, _ column: Int) -> String { literal(text, for: columns[column], backslashEscapes: backslashEscapes) }
        // Rows are found by their original primary key, even if the key itself was edited.
        func whereClause(_ row: Int) -> String {
            primaryKey.map { column in
                let original = rows[row][column]
                return original == nil ? "\(name(column)) IS NULL" : "\(name(column)) = \(value(original, column))"
            }.joined(separator: " AND ")
        }

        var lines: [String] = []
        for row in edits.deleted.sorted() {
            lines.append("DELETE FROM \(target) WHERE \(whereClause(row));")
        }
        for row in edits.updates.keys.sorted() where !edits.deleted.contains(row) {
            guard let changes = edits.updates[row], !changes.isEmpty else { continue }
            let assignments = changes.keys.sorted().map { "\(name($0)) = \(value(changes[$0] ?? nil, $0))" }
            lines.append("UPDATE \(target) SET \(assignments.joined(separator: ", ")) WHERE \(whereClause(row));")
        }
        for values in edits.inserted {
            let set = values.keys.sorted()
            if set.isEmpty {
                lines.append("INSERT INTO \(target) () VALUES ();")
            } else {
                let names = set.map(name).joined(separator: ", ")
                let literals = set.map { value(values[$0] ?? nil, $0) }.joined(separator: ", ")
                lines.append("INSERT INTO \(target) (\(names)) VALUES (\(literals));")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Numbers stay unquoted, NULL is real NULL, binary shown as 0x… goes back as a hex literal.
    public static func literal(_ value: String?, for column: ColumnInfo, backslashEscapes: Bool = true) -> String {
        guard let value else { return "NULL" }
        if isNumeric(column.typeName), value.wholeMatch(of: numberPattern) != nil {
            return value
        }
        if column.isBinary, value.hasPrefix("0x"), value.count > 2, value.dropFirst(2).allSatisfy(\.isHexDigit) {
            return value
        }
        return SQL.quoteString(value, backslashEscapes: backslashEscapes)
    }

    /// A plain decimal number like `-12`, `3.50` or `1e6`; anything else is quoted.
    nonisolated(unsafe) private static let numberPattern = /[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?/

    public static func isNumeric(_ typeName: String) -> Bool {
        ["TINY", "SHORT", "LONG", "LONGLONG", "INT24", "FLOAT", "DOUBLE", "DECIMAL", "NEWDECIMAL", "YEAR"].contains(typeName)
    }
}
