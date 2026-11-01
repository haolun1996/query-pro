import Foundation

/// RFC 4180 CSV reading, for importing into a table.
public enum CSV {
    public static let delimiters: [Character] = [",", ";", "\t", "|"]

    /// Rows of fields. An unquoted empty field and an unquoted `\N` are `nil`; a quoted `""` is an empty string.
    /// That matches SQ Pro's own CSV export, which writes NULL as nothing and an empty string as `""`.
    /// A leading BOM is skipped; blank lines are dropped.
    public static func parse(_ text: String, delimiter: Character = ",") -> [[String?]] {
        let bytes = Array(text.utf8)
        let separator = delimiter.asciiValue ?? UInt8(ascii: ",")
        let quote = UInt8(ascii: "\""), cr = UInt8(ascii: "\r"), lf = UInt8(ascii: "\n")
        var rows: [[String?]] = []
        var row: [String?] = []
        var field: [UInt8] = []
        var quoted = false
        var inQuotes = false
        var i = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0

        func endField() {
            if quoted {
                row.append(String(decoding: field, as: UTF8.self))
            } else if field.isEmpty || field == [UInt8(ascii: "\\"), UInt8(ascii: "N")] {
                row.append(nil)
            } else {
                row.append(String(decoding: field, as: UTF8.self))
            }
            field.removeAll(keepingCapacity: true)
            quoted = false
        }
        func endRow() {
            endField()
            // A blank line reads as one empty field.
            if !(row.count == 1 && row[0] == nil) { rows.append(row) }
            row = []
        }

        while i < bytes.count {
            let byte = bytes[i]
            if inQuotes {
                if byte == quote {
                    if i + 1 < bytes.count, bytes[i + 1] == quote {
                        field.append(quote)
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(byte)
                }
            } else if byte == quote, field.isEmpty, !quoted {
                inQuotes = true
                quoted = true
            } else if byte == separator {
                endField()
            } else if byte == cr || byte == lf {
                if byte == cr, i + 1 < bytes.count, bytes[i + 1] == lf { i += 1 }
                endRow()
            } else {
                field.append(byte)
            }
            i += 1
        }
        if !field.isEmpty || quoted || !row.isEmpty { endRow() }
        return rows
    }

    /// The candidate that splits the first line into the most fields, ignoring quoted text. Comma by default.
    public static func detectDelimiter(_ text: String) -> Character {
        var counts: [Character: Int] = [:]
        var inQuotes = false
        for character in text.prefix(10_000) {
            if character == "\"" { inQuotes.toggle() }
            if inQuotes { continue }
            if character == "\n" || character == "\r\n" || character == "\r" { break }
            if delimiters.contains(character) { counts[character, default: 0] += 1 }
        }
        return counts.max { a, b in a.value < b.value || (a.value == b.value && delimiters.firstIndex(of: a.key)! > delimiters.firstIndex(of: b.key)!) }?.key ?? ","
    }

    /// UTF-8, or Windows-1252 (what Excel writes on many systems) when the file isn't valid UTF-8.
    public static func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        return String(decoding: data, as: UTF8.self)
    }
}

/// How CSV rows become INSERT statements for one table.
public struct CSVImportPlan: Sendable {
    public enum Duplicates: String, CaseIterable, Sendable {
        /// Plain INSERT: a duplicate key stops the import and rolls it back.
        case stop
        /// INSERT IGNORE.
        case skip
        /// REPLACE.
        case replace
    }

    public struct Target: Sendable, Equatable {
        public var column: String
        /// CSV field index.
        public var source: Int
        /// BLOB / BINARY columns take `0x…` values as hex literals.
        public var isBinary: Bool

        public init(column: String, source: Int, isBinary: Bool = false) {
            self.column = column
            self.source = source
            self.isBinary = isBinary
        }
    }

    public var schema: String
    public var table: String
    public var targets: [Target]
    /// Empty unquoted fields become NULL (otherwise an empty string).
    public var emptyIsNull = true
    /// The unquoted or quoted text `NULL` becomes NULL.
    public var nullText = true
    public var duplicates = Duplicates.stop
    public var backslashEscapes = true

    public init(schema: String, table: String, targets: [Target]) {
        self.schema = schema
        self.table = table
        self.targets = targets
    }

    /// Multi-row INSERTs of up to `maxRows` rows or about `maxBytes` each, with the index of each batch's first row.
    public func statements(for rows: [[String?]], maxRows: Int = 500, maxBytes: Int = 1 << 20) -> [(firstRow: Int, sql: String)] {
        let verb = switch duplicates {
        case .stop: "INSERT INTO"
        case .skip: "INSERT IGNORE INTO"
        case .replace: "REPLACE INTO"
        }
        let head = "\(verb) \(SQL.quoteIdentifier(schema)).\(SQL.quoteIdentifier(table)) ("
            + targets.map { SQL.quoteIdentifier($0.column) }.joined(separator: ", ") + ") VALUES\n"
        var statements: [(Int, String)] = []
        var tuples: [String] = []
        var size = 0
        var first = 0
        for (index, row) in rows.enumerated() {
            let tuple = "(" + targets.map { literal(index: $0.source, in: row, binary: $0.isBinary) }.joined(separator: ", ") + ")"
            if !tuples.isEmpty, tuples.count >= maxRows || size + tuple.utf8.count > maxBytes {
                statements.append((first, head + tuples.joined(separator: ",\n")))
                tuples = []
                size = 0
                first = index
            }
            tuples.append(tuple)
            size += tuple.utf8.count + 2
        }
        if !tuples.isEmpty { statements.append((first, head + tuples.joined(separator: ",\n"))) }
        return statements
    }

    func literal(index: Int, in row: [String?], binary: Bool) -> String {
        // A short row is missing its last fields: treat them as empty.
        let field = index < row.count ? row[index] : nil
        guard let value = field else { return emptyIsNull ? "NULL" : "''" }
        if nullText, value == "NULL" { return "NULL" }
        if binary, value.count > 2, value.hasPrefix("0x"), value.dropFirst(2).allSatisfy(\.isHexDigit) { return value }
        return SQL.quoteString(value, backslashEscapes: backslashEscapes)
    }
}
