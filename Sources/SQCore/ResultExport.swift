import Foundation

/// Writes result rows as CSV, JSON or SQL INSERT statements.
public enum ResultExport {
    public enum Format: String, CaseIterable, Sendable {
        case csv, json, insert

        public var title: String {
            switch self {
            case .csv: "CSV"
            case .json: "JSON"
            case .insert: "SQL INSERT"
            }
        }

        public var fileExtension: String {
            switch self {
            case .csv: "csv"
            case .json: "json"
            case .insert: "sql"
            }
        }
    }

    /// `table` is the INSERT target, already quoted (e.g. `` `pos`.`admins` ``); the other formats ignore it.
    public static func export(
        _ format: Format, columns: [ColumnInfo], rows: [[String?]], table: String, backslashEscapes: Bool = true
    ) -> String {
        switch format {
        case .csv: csv(columns: columns, rows: rows)
        case .json: json(columns: columns, rows: rows)
        case .insert: insert(into: table, columns: columns, rows: rows, backslashEscapes: backslashEscapes)
        }
    }

    /// RFC 4180: a header row, CRLF line ends, quotes where needed. NULL is an empty field and an
    /// empty string is `""`, so the two stay distinguishable.
    public static func csv(columns: [ColumnInfo], rows: [[String?]]) -> String {
        func field(_ value: String?) -> String {
            guard let value else { return "" }
            let needsQuotes = value.isEmpty || value.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
                || value.first?.isWhitespace == true || value.last?.isWhitespace == true
            return needsQuotes ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
        }
        var lines = [columns.map { field($0.name) }.joined(separator: ",")]
        for row in rows {
            lines.append(row.map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// An array of objects, one per line, keys in column order. Numbers stay numbers, NULL is `null`.
    /// Repeated column names (e.g. `id` from a join) get `_2`, `_3` so no value is lost.
    public static func json(columns: [ColumnInfo], rows: [[String?]]) -> String {
        var used: [String: Int] = [:]
        let keys = columns.map { column in
            let count = (used[column.name] ?? 0) + 1
            used[column.name] = count
            return jsonString(count == 1 ? column.name : "\(column.name)_\(count)")
        }
        let numeric = columns.map { ChangeScript.isNumeric($0.typeName) }
        let objects = rows.map { row in
            let pairs = row.indices.map { index -> String in
                let value: String
                if let text = row[index] {
                    value = numeric[index] && text.wholeMatch(of: jsonNumber) != nil ? text : jsonString(text)
                } else {
                    value = "null"
                }
                return "\(keys[index]): \(value)"
            }
            return "  {" + pairs.joined(separator: ", ") + "}"
        }
        return objects.isEmpty ? "[]\n" : "[\n" + objects.joined(separator: ",\n") + "\n]\n"
    }

    /// One INSERT per row, values written the same way as the Apply dialog's script.
    public static func insert(into table: String, columns: [ColumnInfo], rows: [[String?]], backslashEscapes: Bool = true) -> String {
        let names = columns.map { SQL.quoteIdentifier($0.originalName.isEmpty ? $0.name : $0.originalName) }.joined(separator: ", ")
        return rows.map { row in
            let values = row.indices.map { ChangeScript.literal(row[$0], for: columns[$0], backslashEscapes: backslashEscapes) }
            return "INSERT INTO \(table) (\(names)) VALUES (\(values.joined(separator: ", ")));\n"
        }.joined()
    }

    static func jsonString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// JSON is stricter than SQL: no `+1`, `.5` or `1.`.
    nonisolated(unsafe) private static let jsonNumber = /-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?/
}
