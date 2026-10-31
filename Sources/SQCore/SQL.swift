import Foundation

public enum SQLTokenKind: Sendable, Equatable {
    case keyword
    case identifier
    /// `` `name` ``
    case quotedIdentifier
    case string
    case number
    case comment
    /// `@var` or `@@system_var`
    case variable
    case semicolon
    case openParen
    case closeParen
    case symbol
    case whitespace
}

public struct SQLToken: Sendable, Equatable {
    public var kind: SQLTokenKind
    /// UTF-16 offsets, so they map straight onto `NSRange` in text views.
    public var range: Range<Int>
}

public struct SQLStatement: Sendable, Equatable {
    /// From the first real token to the closing `;` (inclusive), in UTF-16 offsets.
    public var range: Range<Int>
    /// The statement without its trailing `;`.
    public var text: String
}

/// MySQL-aware tokenizing: strings, backticks, `--`/`#`/`/* */` comments. Used for highlighting,
/// splitting a script into statements and deciding where `LIMIT` may be added.
public enum SQL {
    public static func tokenize(_ text: String) -> [SQLToken] {
        let chars = Array(text.utf16)
        var tokens: [SQLToken] = []
        var i = 0
        let n = chars.count

        func at(_ index: Int) -> UInt16 { index < n ? chars[index] : 0 }

        while i < n {
            let start = i
            let c = chars[i]
            let kind: SQLTokenKind

            if isSpace(c) {
                while i < n, isSpace(chars[i]) { i += 1 }
                kind = .whitespace
            } else if c == ascii("#") || (c == ascii("-") && at(i + 1) == ascii("-") && (i + 2 >= n || isSpace(at(i + 2)))) {
                while i < n, chars[i] != ascii("\n") { i += 1 }
                kind = .comment
            } else if c == ascii("/") && at(i + 1) == ascii("*") {
                i += 2
                while i < n, !(chars[i] == ascii("*") && at(i + 1) == ascii("/")) { i += 1 }
                i = min(i + 2, n)
                kind = .comment
            } else if c == ascii("'") || c == ascii("\"") {
                i = endOfQuoted(chars, from: i, quote: c, backslashEscapes: true)
                kind = .string
            } else if c == ascii("`") {
                i = endOfQuoted(chars, from: i, quote: c, backslashEscapes: false)
                kind = .quotedIdentifier
            } else if isDigit(c) || (c == ascii(".") && isDigit(at(i + 1))) {
                i += 1
                while i < n, isWordChar(chars[i]) || chars[i] == ascii(".") { i += 1 }
                kind = .number
            } else if c == ascii("@") {
                i += 1
                if at(i) == ascii("@") { i += 1 }
                if at(i) == ascii("`") || at(i) == ascii("'") || at(i) == ascii("\"") {
                    i = endOfQuoted(chars, from: i, quote: at(i), backslashEscapes: at(i) != ascii("`"))
                } else {
                    while i < n, isWordChar(chars[i]) || chars[i] == ascii(".") { i += 1 }
                }
                kind = .variable
            } else if isWordChar(c) {
                while i < n, isWordChar(chars[i]) { i += 1 }
                let word = String(utf16CodeUnits: Array(chars[start..<i]), count: i - start).uppercased()
                kind = keywords.contains(word) ? .keyword : .identifier
            } else if c == ascii(";") {
                i += 1
                kind = .semicolon
            } else if c == ascii("(") {
                i += 1
                kind = .openParen
            } else if c == ascii(")") {
                i += 1
                kind = .closeParen
            } else {
                i += 1
                kind = .symbol
            }
            tokens.append(SQLToken(kind: kind, range: start..<i))
        }
        return tokens
    }

    /// Splits a script on `;` outside strings and comments. Comment-only chunks are skipped.
    public static func statements(in text: String) -> [SQLStatement] {
        let utf16 = Array(text.utf16)
        var statements: [SQLStatement] = []
        var start: Int?
        var lastCode = 0

        func finish(end: Int) {
            guard let begin = start else { return }
            let body = String(utf16CodeUnits: Array(utf16[begin..<lastCode]), count: lastCode - begin)
            statements.append(SQLStatement(range: begin..<end, text: body))
            start = nil
        }

        for token in tokenize(text) {
            switch token.kind {
            case .whitespace, .comment:
                continue
            case .semicolon:
                finish(end: token.range.upperBound)
            default:
                if start == nil { start = token.range.lowerBound }
                lastCode = token.range.upperBound
            }
        }
        finish(end: lastCode)
        return statements
    }

    /// The statement the cursor is in. Between statements it picks the one just before the cursor
    /// (so a cursor right after `;` still runs that line), or the first one when above everything.
    public static func statement(at offset: Int, in statements: [SQLStatement]) -> SQLStatement? {
        if let inside = statements.first(where: { $0.range.lowerBound <= offset && offset <= $0.range.upperBound }) {
            return inside
        }
        return statements.last(where: { $0.range.upperBound <= offset }) ?? statements.first
    }

    /// Adds `LIMIT n` to a plain `SELECT` that has no top-level `LIMIT` of its own.
    /// Leaves everything else alone, including `SELECT … INTO` and locking reads (`FOR UPDATE`).
    public static func applyingLimit(_ limit: Int?, to sql: String) -> (sql: String, limited: Bool) {
        guard let limit else { return (sql, false) }
        let code = tokenize(sql).filter { $0.kind != .whitespace && $0.kind != .comment }
        let utf16 = Array(sql.utf16)
        func word(_ token: SQLToken) -> String {
            String(utf16CodeUnits: Array(utf16[token.range]), count: token.range.count).uppercased()
        }

        guard let first = code.first.map(word), first == "SELECT" || first == "WITH" else { return (sql, false) }
        var depth = 0
        var sawSelect = first == "SELECT"
        for token in code {
            switch token.kind {
            case .openParen: depth += 1
            case .closeParen: depth -= 1
            case .keyword where depth == 0:
                let keyword = word(token)
                if keyword == "SELECT" { sawSelect = true }
                if ["LIMIT", "INTO", "FOR", "LOCK", "PROCEDURE"].contains(keyword) { return (sql, false) }
                if first == "WITH", ["UPDATE", "DELETE", "INSERT"].contains(keyword) { return (sql, false) }
            default:
                break
            }
        }
        guard sawSelect else { return (sql, false) }
        // A new line, in case the statement ends with a `--` comment.
        return (sql + "\nLIMIT \(limit)", true)
    }

    /// Uppercases keywords and starts the main clauses of each statement on a new line.
    public static func beautify(_ text: String) -> String {
        let utf16 = Array(text.utf16)
        let clauses: Set<String> = ["FROM", "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "UNION", "SET", "VALUES",
                                    "JOIN", "LEFT", "RIGHT", "INNER", "CROSS", "OUTER", "ON"]
        let joinModifiers: Set<String> = ["LEFT", "RIGHT", "INNER", "CROSS", "OUTER", "NATURAL", "STRAIGHT_JOIN"]
        var output = ""
        var depth = 0
        var previousKeyword = ""
        for token in tokenize(text) {
            var piece = String(utf16CodeUnits: Array(utf16[token.range]), count: token.range.count)
            switch token.kind {
            case .openParen: depth += 1
            case .closeParen: depth = max(0, depth - 1)
            case .semicolon: previousKeyword = ""
            case .keyword:
                piece = piece.uppercased()
                let joinContinues = (piece == "JOIN" || piece == "OUTER") && joinModifiers.contains(previousKeyword)
                if depth == 0, clauses.contains(piece), !joinContinues, piece != "ON" {
                    while output.last == " " || output.last == "\t" { output.removeLast() }
                    if let last = output.last, last != "\n" { output += "\n" }
                }
                previousKeyword = piece
            default:
                break
            }
            if token.kind == .whitespace, output.last == "\n", !piece.contains("\n") { continue }
            output += piece
        }
        return output
    }

    // MARK: Quoting

    /// `` `name` `` with backticks doubled.
    public static func quoteIdentifier(_ name: String) -> String {
        "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
    }

    /// `'value'` with quotes and backslashes escaped.
    public static func quoteString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "'\(escaped)'"
    }

    // MARK: Helpers

    private static func endOfQuoted(_ chars: [UInt16], from start: Int, quote: UInt16, backslashEscapes: Bool) -> Int {
        var i = start + 1
        while i < chars.count {
            let c = chars[i]
            if backslashEscapes && c == ascii("\\") {
                i += 2
                continue
            }
            if c == quote {
                // A doubled quote is an escaped quote, not the end.
                if i + 1 < chars.count, chars[i + 1] == quote {
                    i += 2
                    continue
                }
                return i + 1
            }
            i += 1
        }
        return chars.count
    }

    private static func ascii(_ character: Character) -> UInt16 { UInt16(character.asciiValue!) }
    private static func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 12 }
    private static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    private static func isWordChar(_ c: UInt16) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || isDigit(c) || c == 95 || c == 36 || c > 127
    }

    public static let keywords: Set<String> = [
        "ACCESSIBLE", "ADD", "ALL", "ALTER", "ANALYZE", "AND", "AS", "ASC", "AUTO_INCREMENT", "BEFORE", "BEGIN",
        "BETWEEN", "BIGINT", "BINARY", "BLOB", "BOOLEAN", "BOTH", "BY", "CALL", "CASCADE", "CASE", "CHANGE", "CHAR",
        "CHARACTER", "CHARSET", "CHECK", "COLLATE", "COLUMN", "COLUMNS", "COMMENT", "COMMIT", "CONSTRAINT", "CREATE",
        "CROSS", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "DATABASE", "DATABASES", "DATE", "DATETIME",
        "DECIMAL", "DECLARE", "DEFAULT", "DELETE", "DESC", "DESCRIBE", "DISTINCT", "DIV", "DO", "DOUBLE", "DROP",
        "DUPLICATE", "EACH", "ELSE", "ELSEIF", "END", "ENGINE", "ENUM", "ESCAPE", "EXISTS", "EXPLAIN", "FALSE",
        "FETCH", "FLOAT", "FOR", "FOREIGN", "FROM", "FULL", "FULLTEXT", "FUNCTION", "GRANT", "GROUP", "HAVING", "IF",
        "IGNORE", "IN", "INDEX", "INNER", "INSERT", "INT", "INTEGER", "INTERVAL", "INTO", "IS", "JOIN", "JSON", "KEY",
        "KEYS", "KILL", "LEADING", "LEFT", "LIKE", "LIMIT", "LOCK", "LONGTEXT", "MEDIUMTEXT", "MODIFY", "NATURAL",
        "NOT", "NULL", "OFFSET", "ON", "OR", "ORDER", "OUTER", "OVER", "PARTITION", "PRIMARY", "PROCEDURE",
        "PROCESSLIST", "REFERENCES", "REGEXP", "RENAME", "REPLACE", "RETURN", "RETURNS", "REVOKE", "RIGHT",
        "ROLLBACK", "ROW", "ROWS", "SCHEMA", "SCHEMAS", "SELECT", "SET", "SHARE", "SHOW", "SMALLINT", "START",
        "STATUS", "STRAIGHT_JOIN", "TABLE", "TABLES", "TEMPORARY", "TEXT", "THEN", "TIME", "TIMESTAMP", "TINYINT",
        "TO", "TRAILING", "TRANSACTION", "TRIGGER", "TRUE", "TRUNCATE", "UNION", "UNIQUE", "UNLOCK", "UNSIGNED",
        "UPDATE", "USE", "USING", "VALUES", "VARCHAR", "VARIABLES", "VIEW", "WHEN", "WHERE", "WHILE", "WINDOW",
        "WITH", "XOR",
    ]
}
