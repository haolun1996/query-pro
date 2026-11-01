import Foundation

/// What autocomplete knows about the server: every schema name, and tables with columns for the schemas loaded so far.
public struct CompletionCatalog: Sendable, Equatable {
    public struct Column: Sendable, Equatable {
        public var name: String
        public var type: String

        public init(name: String, type: String) {
            self.name = name
            self.type = type
        }
    }

    public struct Table: Sendable, Equatable {
        public var name: String
        public var isView: Bool
        public var columns: [Column]

        public init(name: String, isView: Bool = false, columns: [Column]) {
            self.name = name
            self.isView = isView
            self.columns = columns
        }
    }

    public var schemas: [String]
    /// The schema unqualified names resolve against (`USE …`).
    public var currentSchema: String?
    /// Schema name → its tables. A schema is missing until it has been loaded.
    public var tables: [String: [Table]]

    public init(schemas: [String] = [], currentSchema: String? = nil, tables: [String: [Table]] = [:]) {
        self.schemas = schemas
        self.currentSchema = currentSchema
        self.tables = tables
    }

    /// The schema as the server spells it. Names are compared case-insensitively, like MySQL on macOS and Windows.
    public func schema(named name: String) -> String? {
        schemas.first { $0 == name } ?? schemas.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// `nil` when the schema hasn't been loaded yet.
    public func tables(in schema: String) -> [Table]? {
        if let exact = tables[schema] { return exact }
        return tables.first { $0.key.caseInsensitiveCompare(schema) == .orderedSame }?.value
    }

    public func table(_ name: String, in schema: String) -> Table? {
        guard let tables = tables(in: schema) else { return nil }
        return tables.first { $0.name == name } ?? tables.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

public struct CompletionItem: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Hashable {
        case column, table, view, schema, keyword, function
    }

    public var kind: Kind
    /// What the list shows.
    public var name: String
    /// Shown dimmed on the right: a column's type, "view", …
    public var detail: String
    /// What replaces the typed word.
    public var insertion: String
}

/// A table named in the statement, so `alias.` and bare column names can be completed.
public struct TableReference: Sendable, Equatable {
    public var schema: String?
    public var name: String
    public var alias: String?
}

/// Where the cursor is and what is being typed there.
public struct CompletionRequest: Sendable, Equatable {
    public enum Place: Sendable, Equatable {
        /// After FROM, JOIN, UPDATE, INTO …: a table name goes here.
        case table
        /// After USE.
        case schema
        /// Anywhere else: columns, keywords, functions.
        case expression
    }

    /// The text to replace, in UTF-16 offsets: the whole word under the cursor, including an opening backtick.
    public var range: Range<Int>
    /// The part of the word before the cursor, without the backtick.
    public var prefix: String
    /// The user started the name with a backtick.
    public var isQuoted: Bool
    /// Names before the word, separated by dots: `a.` → `["a"]`, `pos.admins.` → `["pos", "admins"]`.
    public var qualifier: [String]
    public var place: Place
    public var tables: [TableReference]
}

/// Context-aware completion for the SQL editor. Pure functions, so they're unit-tested without a server.
public enum SQLCompletion {
    public static let maxItems = 300

    /// `nil` inside strings, comments, numbers and variables, where there's nothing to complete.
    public static func request(in text: String, at cursor: Int) -> CompletionRequest? {
        let utf16 = Array(text.utf16)
        guard cursor >= 0, cursor <= utf16.count else { return nil }
        let all = SQL.tokenize(text)

        // Only the statement around the cursor matters.
        var lower = 0
        var upper = all.count
        for (index, token) in all.enumerated() where token.kind == .semicolon {
            if token.range.upperBound <= cursor {
                lower = index + 1
            } else {
                upper = index
                break
            }
        }
        let tokens = Array(all[lower..<upper])
        func string(_ range: Range<Int>) -> String {
            String(utf16CodeUnits: Array(utf16[range]), count: range.count)
        }

        // The word being typed.
        var range = cursor..<cursor
        var prefix = ""
        var isQuoted = false
        var wordIndex = tokens.firstIndex { $0.range.lowerBound >= cursor } ?? tokens.count
        if let index = tokens.firstIndex(where: { $0.range.lowerBound < cursor && cursor <= $0.range.upperBound }) {
            let token = tokens[index]
            switch token.kind {
            case .string, .comment, .number, .variable:
                return nil
            case .identifier, .keyword:
                range = token.range
                prefix = string(token.range.lowerBound..<cursor)
                wordIndex = index
            case .quotedIdentifier:
                let closed = token.range.count > 1 && utf16[token.range.upperBound - 1] == UInt16(UInt8(ascii: "`"))
                if closed && cursor == token.range.upperBound { return nil }
                range = token.range
                prefix = string(token.range.lowerBound + 1..<cursor)
                isQuoted = true
                wordIndex = index
            default:
                wordIndex = index + 1
            }
        }

        // `schema.table.` before the word, with no spaces around the dots.
        var qualifier: [String] = []
        var start = wordIndex
        var boundary = range.lowerBound
        while qualifier.count < 2, start >= 2 {
            let dot = tokens[start - 1]
            let name = tokens[start - 2]
            guard dot.kind == .symbol, string(dot.range) == ".", dot.range.upperBound == boundary,
                  isName(name), name.range.upperBound == dot.range.lowerBound
            else { break }
            qualifier.insert(identifier(string(name.range)), at: 0)
            start -= 2
            boundary = name.range.lowerBound
        }

        let significant = tokens.filter { $0.kind != .whitespace && $0.kind != .comment }
        let before = significant.filter { $0.range.upperBound <= boundary }
        let place = place(after: before, string: string)
        let references = tableReferences(in: significant, string: string).filter { reference in
            // The name being typed isn't a reference yet.
            !(reference.range.lowerBound <= cursor && cursor <= reference.range.upperBound)
        }.map(\.reference)

        return CompletionRequest(
            range: range, prefix: prefix, isQuoted: isQuoted, qualifier: qualifier, place: place, tables: references
        )
    }

    /// Suggestions for the request, best first: prefix matches, then columns and tables that contain the word.
    public static func suggestions(for request: CompletionRequest, in catalog: CompletionCatalog) -> [CompletionItem] {
        var candidates: [CompletionItem] = []

        func columns(of table: String, in schema: String?, showTable: Bool) -> [CompletionItem] {
            guard let schema = schema ?? catalog.currentSchema, let found = catalog.table(table, in: schema) else { return [] }
            return found.columns.map { column in
                CompletionItem(
                    kind: .column, name: column.name,
                    detail: showTable ? "\(column.type) · \(found.name)" : column.type,
                    insertion: quoted(column.name, request: request)
                )
            }
        }
        func tables(in schema: String?) -> [CompletionItem] {
            guard let schema, let tables = catalog.tables(in: schema) else { return [] }
            return tables.map { table in
                CompletionItem(
                    kind: table.isView ? .view : .table, name: table.name, detail: table.isView ? "view" : "table",
                    insertion: quoted(table.name, request: request)
                )
            }
        }
        var schemaItems: [CompletionItem] {
            catalog.schemas.map { CompletionItem(kind: .schema, name: $0, detail: "schema", insertion: quoted($0, request: request)) }
        }

        switch request.qualifier.count {
        case 0:
            switch request.place {
            case .schema:
                candidates = schemaItems
            case .table:
                candidates = tables(in: catalog.currentSchema) + schemaItems
            case .expression:
                let showTable = request.tables.count > 1
                for reference in request.tables {
                    candidates += columns(of: reference.name, in: reference.schema, showTable: showTable)
                }
                if !request.isQuoted {
                    candidates += keywordItems(request) + functionItems(request)
                }
                candidates += tables(in: catalog.currentSchema) + schemaItems
            }
        case 1:
            let name = request.qualifier[0]
            let reference = request.tables.first { $0.alias?.caseInsensitiveCompare(name) == .orderedSame }
                ?? request.tables.first { $0.alias == nil && $0.name.caseInsensitiveCompare(name) == .orderedSame }
            if let reference {
                candidates = columns(of: reference.name, in: reference.schema, showTable: false)
            } else {
                candidates = columns(of: name, in: nil, showTable: false)
            }
            if let schema = catalog.schema(named: name) {
                candidates += tables(in: schema)
            }
        case 2:
            candidates = columns(of: request.qualifier[1], in: request.qualifier[0], showTable: false)
        default:
            break
        }

        let needle = request.prefix.lowercased()
        var seen = Set<String>()
        var prefixMatches: [CompletionItem] = []
        var otherMatches: [CompletionItem] = []
        for item in candidates {
            let name = item.name.lowercased()
            guard seen.insert("\(item.kind)/\(name)").inserted else { continue }
            if needle.isEmpty || name.hasPrefix(needle) {
                prefixMatches.append(item)
            } else if needle.count >= 2, [.column, .table, .view].contains(item.kind), name.contains(needle) {
                otherMatches.append(item)
            }
        }
        let items = prefixMatches + otherMatches
        // Nothing to offer when the word is already complete.
        if items.count == 1, items[0].name.caseInsensitiveCompare(request.prefix) == .orderedSame { return [] }
        return Array(items.prefix(maxItems))
    }

    /// Schemas the request needs columns for that the catalog hasn't loaded yet, as the server spells them.
    public static func schemasToLoad(for request: CompletionRequest, in catalog: CompletionCatalog) -> [String] {
        var names: [String] = []
        if let current = catalog.currentSchema { names.append(current) }
        names += request.tables.compactMap(\.schema)
        if let first = request.qualifier.first { names.append(first) }
        var result: [String] = []
        for name in names {
            guard let schema = catalog.schema(named: name), catalog.tables(in: schema) == nil, !result.contains(schema) else { continue }
            result.append(schema)
        }
        return result
    }

    // MARK: Parsing

    private static let tableKeywords: Set<String> = ["FROM", "JOIN", "STRAIGHT_JOIN", "UPDATE", "INTO", "TABLE", "DESCRIBE", "TRUNCATE"]
    /// Keywords that end a FROM list, so a later comma means a column again.
    private static let clauseKeywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "ON", "USING", "SET", "GROUP", "ORDER", "HAVING", "LIMIT", "UNION", "VALUES", "WINDOW",
        "JOIN", "LEFT", "RIGHT", "INNER", "CROSS", "NATURAL", "OUTER", "STRAIGHT_JOIN", "FOR", "LOCK", "INTO", "UPDATE",
    ]

    private static func place(after tokens: [SQLToken], string: (Range<Int>) -> String) -> CompletionRequest.Place {
        guard let last = tokens.last else { return .expression }
        let word = string(last.range).uppercased()
        if last.kind == .keyword || last.kind == .identifier {
            if word == "USE" { return .schema }
            if tableKeywords.contains(word) { return .table }
            // `DESC t` describes a table; `ORDER BY a DESC` doesn't.
            if word == "DESC", tokens.count == 1 { return .table }
            return .expression
        }
        guard last.kind == .symbol, word == "," else { return .expression }
        // After a comma: still in a FROM list?
        var depth = 0
        for token in tokens.reversed() {
            switch token.kind {
            case .closeParen: depth += 1
            case .openParen:
                if depth == 0 { return .expression }
                depth -= 1
            case .keyword where depth == 0:
                let keyword = string(token.range).uppercased()
                if keyword == "FROM" || keyword == "UPDATE" { return .table }
                if clauseKeywords.contains(keyword) { return .expression }
            default: break
            }
        }
        return .expression
    }

    private static func tableReferences(
        in tokens: [SQLToken], string: (Range<Int>) -> String
    ) -> [(reference: TableReference, range: Range<Int>)] {
        var references: [(TableReference, Range<Int>)] = []
        var inList = false
        func word(_ index: Int) -> String? {
            index < tokens.count && (tokens[index].kind == .keyword || tokens[index].kind == .identifier)
                ? string(tokens[index].range).uppercased() : nil
        }
        func isSymbol(_ index: Int, _ symbol: String) -> Bool {
            index < tokens.count && tokens[index].kind == .symbol && string(tokens[index].range) == symbol
        }
        func parse(at start: Int) {
            guard start < tokens.count, isName(tokens[start]), !clauseKeywords.contains(word(start) ?? "") else { return }
            var index = start
            var schema: String?
            var name = identifier(string(tokens[index].range))
            var range = tokens[index].range
            if isSymbol(index + 1, "."), index + 2 < tokens.count, isName(tokens[index + 2]) {
                schema = name
                name = identifier(string(tokens[index + 2].range))
                range = tokens[index].range.lowerBound..<tokens[index + 2].range.upperBound
                index += 2
            }
            var alias: String?
            var next = index + 1
            if word(next) == "AS" { next += 1 }
            if next < tokens.count, tokens[next].kind == .identifier || tokens[next].kind == .quotedIdentifier {
                alias = identifier(string(tokens[next].range))
            }
            references.append((TableReference(schema: schema, name: name, alias: alias), range))
        }

        for index in tokens.indices {
            if let keyword = word(index), tokens[index].kind == .keyword {
                if tableKeywords.contains(keyword) {
                    parse(at: index + 1)
                    inList = keyword == "FROM" || keyword == "UPDATE"
                } else if clauseKeywords.contains(keyword) {
                    inList = false
                }
            } else if inList, isSymbol(index, ",") {
                parse(at: index + 1)
            }
        }
        return references
    }

    private static func isName(_ token: SQLToken) -> Bool {
        token.kind == .identifier || token.kind == .quotedIdentifier || token.kind == .keyword
    }

    /// Strips backticks and undoubles inner ones.
    private static func identifier(_ text: String) -> String {
        guard text.hasPrefix("`") else { return text }
        var inner = text.dropFirst()
        if inner.hasSuffix("`") { inner = inner.dropLast() }
        return inner.replacingOccurrences(of: "``", with: "`")
    }

    // MARK: Inserting

    /// Backticks when the user typed one, or the name needs them (spaces, reserved words, leading digits).
    static func quoted(_ name: String, request: CompletionRequest) -> String {
        if request.isQuoted || needsQuoting(name) { return SQL.quoteIdentifier(name) }
        return name
    }

    static func needsQuoting(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, !name.isEmpty else { return true }
        if CharacterSet.decimalDigits.contains(first), name.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
            return true
        }
        let plain = name.unicodeScalars.allSatisfy { scalar in
            scalar.value > 127 || CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$"
        }
        return !plain || reservedWords.contains(name.uppercased())
    }

    /// Typed in lower case → insert lower case; otherwise upper case.
    private static func keywordCase(_ text: String, _ request: CompletionRequest) -> String {
        let typed = request.prefix
        return !typed.isEmpty && typed == typed.lowercased() ? text.lowercased() : text
    }

    private static func keywordItems(_ request: CompletionRequest) -> [CompletionItem] {
        completionKeywords.map { keyword in
            CompletionItem(kind: .keyword, name: keyword, detail: "", insertion: keywordCase(keyword, request))
        }
    }

    private static func functionItems(_ request: CompletionRequest) -> [CompletionItem] {
        functions.map { function in
            CompletionItem(kind: .function, name: function, detail: "function", insertion: keywordCase(function, request) + "(")
        }
    }

    /// Roughly in order of how often they're typed, since equal matches keep this order.
    static let completionKeywords = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "NULL", "IS NULL", "IS NOT NULL", "IN", "LIKE", "BETWEEN",
        "JOIN", "LEFT JOIN", "INNER JOIN", "RIGHT JOIN", "CROSS JOIN", "ON", "USING", "AS", "DISTINCT",
        "GROUP BY", "ORDER BY", "HAVING", "LIMIT", "OFFSET", "ASC", "DESC", "UNION", "UNION ALL", "EXISTS",
        "CASE", "WHEN", "THEN", "ELSE", "END", "INSERT INTO", "VALUES", "UPDATE", "SET", "DELETE FROM",
        "ON DUPLICATE KEY UPDATE", "REPLACE INTO", "CREATE TABLE", "CREATE INDEX", "CREATE VIEW", "ALTER TABLE",
        "ADD COLUMN", "DROP COLUMN", "MODIFY COLUMN", "DROP TABLE", "TRUNCATE TABLE", "SHOW TABLES", "SHOW DATABASES",
        "SHOW COLUMNS FROM", "SHOW CREATE TABLE", "SHOW INDEX FROM", "SHOW PROCESSLIST", "SHOW VARIABLES LIKE",
        "DESCRIBE", "EXPLAIN", "USE", "START TRANSACTION", "COMMIT", "ROLLBACK", "WITH", "OVER", "PARTITION BY",
        "PRIMARY KEY", "FOREIGN KEY", "REFERENCES", "DEFAULT", "AUTO_INCREMENT", "NOT NULL", "UNIQUE", "INDEX",
        "TRUE", "FALSE", "INTERVAL", "REGEXP", "FOR UPDATE",
    ]

    static let functions = [
        "COUNT", "SUM", "AVG", "MIN", "MAX", "CONCAT", "CONCAT_WS", "COALESCE", "IFNULL", "IF", "NULLIF", "NOW",
        "CURDATE", "CURTIME", "DATE", "DATE_FORMAT", "DATE_ADD", "DATE_SUB", "DATEDIFF", "TIMESTAMPDIFF", "STR_TO_DATE",
        "UNIX_TIMESTAMP", "FROM_UNIXTIME", "YEAR", "MONTH", "DAY", "HOUR", "WEEK", "LAST_DAY", "LOWER", "UPPER",
        "LENGTH", "CHAR_LENGTH", "SUBSTRING", "SUBSTRING_INDEX", "TRIM", "REPLACE", "LEFT", "RIGHT", "LPAD", "RPAD",
        "LOCATE", "FIND_IN_SET", "ROUND", "FLOOR", "CEIL", "ABS", "MOD", "FORMAT", "CAST", "CONVERT", "GREATEST",
        "LEAST", "GROUP_CONCAT", "JSON_EXTRACT", "JSON_UNQUOTE", "JSON_OBJECT", "JSON_ARRAY", "JSON_CONTAINS",
        "UUID", "MD5", "SHA2", "ROW_NUMBER", "RANK", "DENSE_RANK", "LAG", "LEAD", "DATABASE", "VERSION",
        "LAST_INSERT_ID", "FOUND_ROWS",
    ]

    /// MySQL 8 reserved words that are also likely names; these need backticks.
    static let reservedWords: Set<String> = [
        "ADD", "ALL", "ALTER", "AND", "AS", "ASC", "BETWEEN", "BY", "CALL", "CASE", "CHANGE", "CHECK", "COLUMN",
        "CONDITION", "CONSTRAINT", "CREATE", "CROSS", "CUBE", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP",
        "DATABASE", "DATABASES", "DEFAULT", "DELETE", "DESC", "DESCRIBE", "DISTINCT", "DIV", "DROP", "DUAL", "EACH",
        "ELSE", "EMPTY", "EXISTS", "EXPLAIN", "FALSE", "FETCH", "FOR", "FOREIGN", "FROM", "FULLTEXT", "FUNCTION",
        "GRANT", "GROUP", "GROUPS", "HAVING", "IF", "IGNORE", "IN", "INDEX", "INNER", "INSERT", "INTERVAL", "INTO",
        "IS", "JOIN", "KEY", "KEYS", "KILL", "LEADING", "LEFT", "LIKE", "LIMIT", "LINES", "LOAD", "LOCK", "MATCH",
        "NATURAL", "NOT", "NULL", "OF", "ON", "OPTION", "OR", "ORDER", "OUT", "OUTER", "OVER", "PARTITION", "PRIMARY",
        "PROCEDURE", "RANGE", "RANK", "READ", "REFERENCES", "REGEXP", "RELEASE", "RENAME", "REPEAT", "REPLACE",
        "REQUIRE", "RETURN", "REVOKE", "RIGHT", "ROW", "ROWS", "SCHEMA", "SCHEMAS", "SELECT", "SET", "SHOW", "SYSTEM",
        "TABLE", "THEN", "TO", "TRAILING", "TRIGGER", "TRUE", "UNION", "UNIQUE", "UNLOCK", "UPDATE", "USAGE", "USE",
        "USING", "VALUES", "WHEN", "WHERE", "WHILE", "WINDOW", "WITH", "WRITE", "XOR",
    ]
}
