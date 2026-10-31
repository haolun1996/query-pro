import Foundation

public struct ColumnInfo: Hashable, Sendable {
    public var name: String
    /// Schema, table and column the value came from. Empty for computed columns like `COUNT(*)`.
    public var schema: String
    public var table: String
    public var originalName: String
    public var typeName: String
    public var isPrimaryKey: Bool
    public var isNotNull: Bool
    public var isBinary: Bool
}

public struct QueryResult: Sendable {
    public var sql: String
    public var columns: [ColumnInfo]
    /// Text-protocol values. `nil` is SQL NULL.
    public var rows: [[String?]]
    /// `true` when the statement returned a result set (even an empty one).
    public var hasResultSet: Bool
    public var affectedRows: UInt64
    public var lastInsertID: UInt64?
    public var info: String
    public var duration: Duration

    /// The one-line summary shown in the Action Output panel.
    public var summary: String {
        if hasResultSet { return "\(rows.count) row(s) returned" }
        var text = "\(affectedRows) row(s) affected"
        if !info.isEmpty { text += " \(info)" }
        return text
    }
}
