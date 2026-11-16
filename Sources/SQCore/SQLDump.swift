import Foundation

/// A `.sql` dump (mysqldump, Workbench, any script): split into statements the way the `mysql` client does,
/// and imported either whole (tables and data) or as data only, into tables that already exist.
public enum SQLDump {
    public enum Mode: String, CaseIterable, Sendable {
        /// Every statement: tables (views, routines…) are created, then filled.
        case structureAndData = "structure_and_data"
        /// Only the rows: INSERT / REPLACE / UPDATE / DELETE and the SET / USE they depend on.
        case dataOnly = "data_only"
    }

    public enum Kind: Sendable, Equatable {
        /// INSERT, REPLACE, UPDATE, DELETE
        case data
        /// CREATE [TEMPORARY] TABLE
        case createTable
        /// CREATE DATABASE / SCHEMA
        case createSchema
        case useSchema
        /// SET … (session settings, `@OLD_…` variables), except autocommit
        case setting
        /// START TRANSACTION, BEGIN, COMMIT, ROLLBACK, SET autocommit, LOCK / UNLOCK TABLES
        case transaction
        /// Everything else: DROP, ALTER, CREATE VIEW / TRIGGER / PROCEDURE, …
        case other
    }

    public struct Statement: Sendable, Equatable {
        /// Without the delimiter. Executable comments (`/*!40101 … */`) stay in: the server runs them.
        public var text: String
        /// 1-based line the statement starts on, for error messages.
        public var line: Int
        public var kind: Kind

        public init(text: String, line: Int) {
            self.text = text
            self.line = line
            self.kind = SQLDump.kind(of: text)
        }
    }

    /// What an import will run.
    public struct Plan: Sendable {
        public var statements: [Statement]
        /// Statements a data-only import leaves out.
        public var skipped: Int
        public var tablesCreated: Int { statements.count { $0.kind == .createTable } }
        public var dataStatements: Int { statements.count { $0.kind == .data } }
        /// Schemas the file switches to (or creates) itself, which win over the chosen target schema.
        public var schemasNamed: [String] {
            var seen: [String] = []
            for statement in statements where statement.kind == .useSchema {
                if let name = SQL.useTarget(statement.text), !seen.contains(name) { seen.append(name) }
            }
            return seen
        }
        public var createsSchemas: Bool { statements.contains { $0.kind == .createSchema } }
    }

    public static func plan(_ statements: [Statement], mode: Mode) -> Plan {
        switch mode {
        case .structureAndData:
            return Plan(statements: statements, skipped: 0)
        case .dataOnly:
            // The import runs as one transaction of its own, so the file's transaction statements go too.
            let kept = statements.filter { [.data, .setting, .useSchema].contains($0.kind) }
            return Plan(statements: kept, skipped: statements.count - kept.count)
        }
    }

    // MARK: Splitting

    /// Splits on the current delimiter outside strings, backticks and comments. `DELIMITER x` lines (as written
    /// around triggers and routines) change it. `/*! … */` and `/*+ … */` count as code; other comments
    /// between statements are dropped.
    public static func statements(in text: String) -> [Statement] {
        let u = Array(text.utf16)
        let n = u.count
        var delimiter: [UInt16] = [semicolon]
        var result: [Statement] = []
        var start: Int?
        var startLine = 1
        var line = 1
        var i = 0
        // Only whitespace so far on this line: where a DELIMITER command may be.
        var atLineStart = true

        func finish(_ end: Int) {
            if let begin = start {
                let body = String(utf16CodeUnits: Array(u[begin..<end]), count: end - begin)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { result.append(Statement(text: body, line: startLine)) }
            }
            start = nil
        }
        func beginCode() {
            if start == nil {
                start = i
                startLine = line
            }
            atLineStart = false
        }
        /// Moves `i` to `end`, counting lines.
        func advance(to end: Int) {
            while i < min(end, n) {
                if u[i] == newline { line += 1 }
                i += 1
            }
        }

        while i < n {
            let c = u[i]
            if atLineStart, let (newDelimiter, lineEnd) = delimiterCommand(u, at: i) {
                // Like the mysql client, the command also ends a statement that had no delimiter yet.
                finish(i)
                if !newDelimiter.isEmpty { delimiter = newDelimiter }
                advance(to: lineEnd)
                continue
            }
            if c == newline {
                line += 1
                i += 1
                atLineStart = true
                continue
            }
            if isSpace(c) {
                i += 1
                continue
            }
            if matches(u, delimiter, at: i) {
                finish(i)
                i += delimiter.count
                atLineStart = false
                continue
            }
            atLineStart = false
            if c == hash || (c == dash && at(u, i + 1) == dash && (i + 2 >= n || isSpace(u[i + 2]))) {
                // To the end of the line; the newline itself starts the next line.
                while i < n, u[i] != newline { i += 1 }
            } else if c == slash && at(u, i + 1) == star {
                let executable = at(u, i + 2) == bang || at(u, i + 2) == plus
                if executable { beginCode() }
                var end = i + 2
                while end < n, !(u[end] == star && at(u, end + 1) == slash) { end += 1 }
                advance(to: end + 2)
            } else if c == singleQuote || c == doubleQuote || c == backtick {
                beginCode()
                advance(to: endOfQuoted(u, from: i, quote: c))
            } else {
                beginCode()
                i += 1
            }
        }
        finish(n)
        return result
    }

    /// `DELIMITER ;;` at `index` (case-insensitive): the new delimiter and where the line ends.
    private static func delimiterCommand(_ u: [UInt16], at index: Int) -> ([UInt16], Int)? {
        let word = Array("delimiter".utf16)
        guard index + word.count < u.count else { return nil }
        for (offset, letter) in word.enumerated() where lower(u[index + offset]) != letter { return nil }
        let after = index + word.count
        guard isSpace(u[after]), u[after] != newline else { return nil }
        var lineEnd = after
        while lineEnd < u.count, u[lineEnd] != newline { lineEnd += 1 }
        let rest = Array(u[after..<lineEnd]).split(whereSeparator: isSpace).first.map(Array.init) ?? []
        return (rest, lineEnd)
    }

    // MARK: Classifying

    public static func kind(of sql: String) -> Kind {
        // Look inside executable comments: `/*!40101 SET NAMES utf8mb4 */` is a SET.
        let head = String(sql.prefix(400))
            .replacingOccurrences(of: #"/\*[!+][0-9]*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "*/", with: " ")
        let utf16 = Array(head.utf16)
        let words = SQL.tokenize(head)
            .filter { $0.kind == .keyword || $0.kind == .identifier }
            .prefix(4)
            .map { String(utf16CodeUnits: Array(utf16[$0.range]), count: $0.range.count).uppercased() }
        guard let first = words.first else { return .other }
        let second = words.dropFirst().first ?? ""
        switch first {
        case "INSERT", "REPLACE", "UPDATE", "DELETE":
            return .data
        case "USE":
            return .useSchema
        case "SET":
            return head.uppercased().contains("AUTOCOMMIT") ? .transaction : .setting
        case "START", "BEGIN", "COMMIT", "ROLLBACK", "LOCK", "UNLOCK":
            return .transaction
        case "CREATE":
            if second == "DATABASE" || second == "SCHEMA" { return .createSchema }
            if second == "TABLE" || (second == "TEMPORARY" && words.dropFirst(2).first == "TABLE") { return .createTable }
            return .other
        default:
            return .other
        }
    }

    // MARK: Helpers

    private static let semicolon = UInt16(UInt8(ascii: ";"))
    private static let newline = UInt16(UInt8(ascii: "\n"))
    private static let hash = UInt16(UInt8(ascii: "#"))
    private static let dash = UInt16(UInt8(ascii: "-"))
    private static let slash = UInt16(UInt8(ascii: "/"))
    private static let star = UInt16(UInt8(ascii: "*"))
    private static let bang = UInt16(UInt8(ascii: "!"))
    private static let plus = UInt16(UInt8(ascii: "+"))
    private static let singleQuote = UInt16(UInt8(ascii: "'"))
    private static let doubleQuote = UInt16(UInt8(ascii: "\""))
    private static let backtick = UInt16(UInt8(ascii: "`"))
    private static let backslash = UInt16(UInt8(ascii: "\\"))

    private static func at(_ u: [UInt16], _ index: Int) -> UInt16 { index < u.count ? u[index] : 0 }
    private static func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 12 }
    private static func lower(_ c: UInt16) -> UInt16 { c >= 65 && c <= 90 ? c + 32 : c }

    private static func matches(_ u: [UInt16], _ pattern: [UInt16], at index: Int) -> Bool {
        guard index + pattern.count <= u.count else { return false }
        for (offset, unit) in pattern.enumerated() where u[index + offset] != unit { return false }
        return true
    }

    /// Just past the closing quote. Backslash escapes inside strings, doubled quotes everywhere.
    private static func endOfQuoted(_ u: [UInt16], from start: Int, quote: UInt16) -> Int {
        var i = start + 1
        while i < u.count {
            if quote != backtick, u[i] == backslash {
                i += 2
                continue
            }
            if u[i] == quote {
                if at(u, i + 1) == quote {
                    i += 2
                    continue
                }
                return i + 1
            }
            i += 1
        }
        return u.count
    }
}

/// Runs a dump's statements on a session of its own. Foreign key checks are off for the session (dumps
/// don't order tables by their references). A data-only import is one transaction: any error rolls it all
/// back. Structure statements commit as they go, so that import stops at the first error with the earlier
/// statements done.
public enum SQLDumpImport {
    public struct Outcome: Sendable {
        public var statements: Int
        public var affectedRows: UInt64
    }

    public struct Failure: Error, LocalizedError, Sendable {
        public var message: String
        public var line: Int?
        /// Statements that ran before it stopped (rolled back again when `rolledBack`).
        public var completed: Int
        public var total: Int
        public var rolledBack: Bool
        public var cancelled: Bool

        public var errorDescription: String? {
            var text = cancelled ? "Stopped." : message
            if let line, !cancelled { text += "\nAt line \(line) (statement \(completed + 1) of \(total))." }
            text += rolledBack
                ? " Rolled back: nothing was imported."
                : completed == 0 ? " Nothing ran." : " The \(completed) statement(s) before it already ran; they can't be rolled back."
            return text
        }
    }

    /// `schema`: `USE` it first, unless empty (then the file's own `USE` decides).
    public static func run(
        _ plan: SQLDump.Plan,
        mode: SQLDump.Mode,
        schema: String?,
        on session: MySQLSession,
        progress: @Sendable (Int) async -> Void = { _ in },
        isCancelled: @Sendable () async -> Bool = { false }
    ) async throws -> Outcome {
        let statements = plan.statements
        let transaction = mode == .dataOnly
        var done = 0
        var affected: UInt64 = 0
        do {
            if let schema, !schema.isEmpty { _ = try await session.execute("USE \(SQL.quoteIdentifier(schema))") }
            _ = try await session.execute(SchemaScript.foreignKeyChecksOff)
            if transaction { _ = try await session.execute("START TRANSACTION") }
            for statement in statements {
                if await isCancelled() { throw CancellationError() }
                affected += try await session.execute(statement.text).affectedRows
                done += 1
                await progress(done)
            }
            if await isCancelled() { throw CancellationError() }
            if transaction { _ = try await session.execute("COMMIT") }
            _ = try? await session.execute(SchemaScript.foreignKeyChecksOn)
            return Outcome(statements: done, affectedRows: affected)
        } catch {
            if transaction { _ = try? await session.execute("ROLLBACK") }
            _ = try? await session.execute(SchemaScript.foreignKeyChecksOn)
            throw Failure(
                message: ErrorText.message(for: error),
                line: done < statements.count ? statements[done].line : nil,
                completed: done,
                total: statements.count,
                rolledBack: transaction,
                cancelled: error is CancellationError
            )
        }
    }
}
