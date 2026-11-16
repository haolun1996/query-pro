import Foundation

/// Writes a schema as a `.sql` dump that `SQLDump` (and the `mysql` client) can read back: tables and data,
/// tables only, or data only. Reads inside one consistent-snapshot, read-only transaction, so the dump is a
/// single point in time for InnoDB tables, and pages through big tables by primary key.
public enum SQLDumpExport {
    public enum Content: String, CaseIterable, Sendable {
        case structureAndData = "structure_and_data"
        case structureOnly = "structure_only"
        case dataOnly = "data_only"

        public var includesStructure: Bool { self != .dataOnly }
        public var includesData: Bool { self != .structureOnly }

        public var title: String {
            switch self {
            case .structureAndData: "tables and data"
            case .structureOnly: "tables only"
            case .dataOnly: "data only"
            }
        }
    }

    public struct Options: Sendable {
        public var content: Content
        /// `nil`: every base table in the schema.
        public var tables: [String]?
        /// Views, stored procedures, functions and triggers (only with structure). With a subset of tables, only
        /// those tables' triggers are written.
        public var includesObjects = true
        /// Rows fetched per query from a table with a primary key.
        public var pageRows = 5_000
        /// One extended INSERT stays under this many bytes (far below the default `max_allowed_packet`).
        public var insertBytes = 1 << 20

        public init(content: Content, tables: [String]? = nil, includesObjects: Bool = true) {
            self.content = content
            self.tables = tables
            self.includesObjects = includesObjects
        }
    }

    public struct Progress: Sendable {
        public var table: String
        public var tablesDone: Int
        public var tableCount: Int
        public var rows: Int
    }

    public struct Outcome: Sendable {
        public var tables = 0
        public var views = 0
        public var routines = 0
        public var triggers = 0
        public var rows = 0
        public var bytes = 0

        public var summary: String {
            var parts = ["\(tables) table(s)"]
            if views > 0 { parts.append("\(views) view(s)") }
            if routines > 0 { parts.append("\(routines) routine(s)") }
            if triggers > 0 { parts.append("\(triggers) trigger(s)") }
            parts.append("\(rows) row(s)")
            return parts.joined(separator: ", ") + ", " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
    }

    public struct ExportError: Error, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// Writes to a temporary file next to `url` and moves it into place at the end, so a failed or stopped
    /// export never leaves half a dump behind (or replaces a good one).
    public static func run(
        schema: String,
        options: Options,
        on session: MySQLSession,
        to url: URL,
        server: String = "",
        progress: @Sendable (Progress) async -> Void = { _ in },
        isCancelled: @Sendable () async -> Bool = { false }
    ) async throws -> Outcome {
        let partial = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).partial")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
            throw ExportError(message: "Can't write to \(url.deletingLastPathComponent().path).")
        }
        let writer = try Writer(url: partial)
        do {
            var outcome = try await write(schema: schema, options: options, session: session, writer: writer, server: server,
                                          progress: progress, isCancelled: isCancelled)
            try writer.close()
            outcome.bytes = writer.bytes
            _ = try FileManager.default.replaceItemAt(url, withItemAt: partial)
            return outcome
        } catch {
            try? writer.close()
            try? FileManager.default.removeItem(at: partial)
            _ = try? await session.execute("ROLLBACK")
            throw error
        }
    }

    private static func write(
        schema: String, options: Options, session: MySQLSession, writer: Writer, server: String,
        progress: @Sendable (Progress) async -> Void, isCancelled: @Sendable () async -> Bool
    ) async throws -> Outcome {
        let s = SQL.quoteString(schema)
        // SHOW CREATE VIEW / TABLE leave out the schema name for objects in the current schema, so the dump can be
        // imported into a schema with another name.
        _ = try await session.execute("USE \(SQL.quoteIdentifier(schema))")
        _ = try await session.execute("SET SESSION time_zone = '+00:00'")
        _ = try await session.execute("SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ")
        _ = try await session.execute("START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY")

        let all = try await session.execute(SchemaScript.tablesQuery(schema)).rows.compactMap { $0.first ?? nil }
        if let wanted = options.tables {
            let unknown = wanted.filter { !all.contains($0) }
            guard unknown.isEmpty else { throw ExportError(message: "No table \(unknown.joined(separator: ", ")) in \(schema).") }
        }
        let tables = options.tables.map { wanted in all.filter { wanted.contains($0) } } ?? all
        let tableCount = tables.count
        let wholeSchema = options.tables == nil
        let objects = options.content.includesStructure && options.includesObjects

        var outcome = Outcome()
        writer.write(header(schema: schema, content: options.content, server: server))

        for (index, table) in tables.enumerated() {
            if await isCancelled() { throw CancellationError() }
            await progress(Progress(table: table, tablesDone: index, tableCount: tables.count, rows: outcome.rows))
            let name = SQL.quoteIdentifier(table)
            if options.content.includesStructure {
                let create = try await session.execute("SHOW CREATE TABLE \(name)").rows.first.flatMap { $0.count > 1 ? $0[1] : nil }
                guard let create else { throw ExportError(message: "No CREATE TABLE for \(table).") }
                writer.write("--\n-- Table \(name)\n--\n\nDROP TABLE IF EXISTS \(name);\n\(create);\n\n")
            }
            if options.content.includesData {
                if !options.content.includesStructure { writer.write("--\n-- Data for \(name)\n--\n\n") }
                try await writeRows(of: table, schema: schema, options: options, session: session, writer: writer, outcome: &outcome,
                                    progress: { rows in await progress(Progress(table: table, tablesDone: index, tableCount: tableCount, rows: rows)) },
                                    isCancelled: isCancelled)
            }
            if objects {
                let triggers = try await session.execute("""
                    SELECT TRIGGER_NAME FROM information_schema.TRIGGERS
                    WHERE TRIGGER_SCHEMA = \(s) AND EVENT_OBJECT_TABLE = \(SQL.quoteString(table)) ORDER BY ACTION_ORDER, TRIGGER_NAME
                    """).rows.compactMap { $0.first ?? nil }
                for trigger in triggers {
                    let body = try await showCreate("TRIGGER", trigger, session: session)
                    writer.write("DROP TRIGGER IF EXISTS \(SQL.quoteIdentifier(trigger));\nDELIMITER ;;\n\(body) ;;\nDELIMITER ;\n\n")
                    outcome.triggers += 1
                }
            }
            outcome.tables += 1
        }

        if objects, wholeSchema {
            let views = try await session.execute("""
                SELECT TABLE_NAME, VIEW_DEFINITION FROM information_schema.VIEWS WHERE TABLE_SCHEMA = \(s) ORDER BY TABLE_NAME
                """).rows.compactMap { row in row[0].map { (name: $0, definition: row[1] ?? "") } }
            for view in orderViews(views) {
                if await isCancelled() { throw CancellationError() }
                let create = try await session.execute("SHOW CREATE VIEW \(SQL.quoteIdentifier(view))").rows.first.flatMap { $0.count > 1 ? $0[1] : nil }
                guard let create else { continue }
                writer.write("--\n-- View \(SQL.quoteIdentifier(view))\n--\n\nDROP VIEW IF EXISTS \(SQL.quoteIdentifier(view));\n\(withoutDefiner(create));\n\n")
                outcome.views += 1
            }
            let routines = try await session.execute("""
                SELECT ROUTINE_NAME, ROUTINE_TYPE FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = \(s) ORDER BY ROUTINE_TYPE, ROUTINE_NAME
                """).rows.compactMap { row in row[0].map { (name: $0, type: row[1] ?? "PROCEDURE") } }
            for routine in routines {
                let kind = routine.type == "FUNCTION" ? "FUNCTION" : "PROCEDURE"
                let body = try await showCreate(kind, routine.name, session: session)
                writer.write("""
                    DROP \(kind) IF EXISTS \(SQL.quoteIdentifier(routine.name));
                    DELIMITER ;;
                    \(body) ;;
                    DELIMITER ;


                    """)
                outcome.routines += 1
            }
        }

        _ = try? await session.execute("COMMIT")
        writer.write(footer)
        await progress(Progress(table: "", tablesDone: tables.count, tableCount: tables.count, rows: outcome.rows))
        return outcome
    }

    /// Extended INSERTs, paged by primary key (`WHERE (pk) > (last) ORDER BY pk LIMIT n`) so a big table never sits
    /// in memory whole. Generated columns are read for paging but not inserted: MySQL computes them.
    private static func writeRows(
        of table: String, schema: String, options: Options, session: MySQLSession, writer: Writer, outcome: inout Outcome,
        progress: @Sendable (Int) async -> Void, isCancelled: @Sendable () async -> Bool
    ) async throws {
        let (s, t) = (SQL.quoteString(schema), SQL.quoteString(table))
        let columns = try await session.execute("""
            SELECT COLUMN_NAME, GENERATION_EXPRESSION FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = \(s) AND TABLE_NAME = \(t) ORDER BY ORDINAL_POSITION
            """).rows.compactMap { row in row[0].map { (name: $0, generated: !(row[1] ?? "").isEmpty) } }
        let key = try await session.execute("""
            SELECT COLUMN_NAME FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = \(s) AND TABLE_NAME = \(t) AND INDEX_NAME = 'PRIMARY' ORDER BY SEQ_IN_INDEX
            """).rows.compactMap { $0.first ?? nil }
        let inserted = columns.indices.filter { !columns[$0].generated }
        guard !inserted.isEmpty else { return }
        let keyIndexes = key.compactMap { name in columns.firstIndex { $0.name == name } }
        let name = SQL.quoteIdentifier(table)
        let select = "SELECT \(columns.map { SQL.quoteIdentifier($0.name) }.joined(separator: ", ")) FROM \(name)"
        let prefix = "INSERT INTO \(name) (\(inserted.map { SQL.quoteIdentifier(columns[$0].name) }.joined(separator: ", "))) VALUES "
        let order = key.map(SQL.quoteIdentifier).joined(separator: ", ")

        var after: String?
        var pending = ""
        func flush() {
            guard !pending.isEmpty else { return }
            writer.write(prefix + pending + ";\n")
            pending = ""
        }
        while true {
            if await isCancelled() { throw CancellationError() }
            let sql: String
            if keyIndexes.isEmpty {
                sql = select
            } else {
                let condition = after.map { " WHERE (\(order)) > (\($0))" } ?? ""
                sql = "\(select)\(condition) ORDER BY \(order) LIMIT \(options.pageRows)"
            }
            let page = try await session.execute(sql)
            for row in page.rows {
                let tuple = "(" + inserted.map { literal(row[$0], page.columns[$0]) }.joined(separator: ",") + ")"
                if !pending.isEmpty, pending.utf8.count + tuple.utf8.count > options.insertBytes { flush() }
                pending += pending.isEmpty ? tuple : "," + tuple
            }
            outcome.rows += page.rows.count
            await progress(outcome.rows)
            guard !keyIndexes.isEmpty, page.rows.count == options.pageRows, let last = page.rows.last else { break }
            after = keyIndexes.map { literal(last[$0], page.columns[$0]) }.joined(separator: ", ")
        }
        flush()
        writer.write("\n")
    }

    /// Like the Apply dialog's values, plus an empty binary value (which the session reads as a bare `0x`).
    static func literal(_ value: String?, _ column: ColumnInfo) -> String {
        if column.isBinary, value == "0x" { return "''" }
        return ChangeScript.literal(value, for: column)
    }

    /// Third column of `SHOW CREATE TRIGGER / PROCEDURE / FUNCTION`, without its DEFINER so it imports anywhere.
    private static func showCreate(_ kind: String, _ name: String, session: MySQLSession) async throws -> String {
        let row = try await session.execute("SHOW CREATE \(kind) \(SQL.quoteIdentifier(name))").rows.first
        guard let row, row.count > 2, let body = row[2] else {
            throw ExportError(message: "Can't read the definition of \(kind.lowercased()) \(name): it needs more privileges.")
        }
        return withoutDefiner(body)
    }

    /// `DEFINER=`user`@`host`` names an account that may not exist where the dump is imported.
    static func withoutDefiner(_ sql: String) -> String {
        sql.replacingOccurrences(of: #"DEFINER\s*=\s*(`(?:[^`]|``)*`|'[^']*'|\w+)@(`(?:[^`]|``)*`|'[^']*'|[\w.%-]+)\s*"#,
                                 with: "", options: .regularExpression)
    }

    /// Views that use other views come after them.
    static func orderViews(_ views: [(name: String, definition: String)]) -> [String] {
        var remaining = views
        var ordered: [String] = []
        while !remaining.isEmpty {
            let pendingNames = Set(remaining.map(\.name))
            let ready = remaining.filter { view in
                !pendingNames.contains { $0 != view.name && view.definition.contains(SQL.quoteIdentifier($0)) }
            }
            // A cycle can't be created in MySQL; if the check is fooled anyway, keep going in name order.
            let next = ready.isEmpty ? [remaining[0]] : ready
            ordered += next.map(\.name)
            let done = Set(next.map(\.name))
            remaining.removeAll { done.contains($0.name) }
        }
        return ordered
    }

    private static func header(schema: String, content: Content, server: String) -> String {
        let date = ISO8601DateFormatter().string(from: Date())
        return """
            -- Query Pro SQL dump
            --
            -- Server: \(server.isEmpty ? "?" : server)    Database: \(schema)
            -- Content: \(content.title)
            -- Exported: \(date)

            /*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
            /*!40101 SET NAMES utf8mb4 */;
            /*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
            /*!40103 SET TIME_ZONE='+00:00' */;
            /*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
            /*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
            /*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;


            """
    }

    private static let footer = """
        /*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
        /*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
        /*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
        /*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;
        /*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;

        -- Dump completed

        """

    /// Buffered UTF-8 output. A failed write (disk full) is thrown by `close`.
    private final class Writer {
        private let handle: FileHandle
        private var buffer = Data()
        private var failure: Error?
        private(set) var bytes = 0

        init(url: URL) throws {
            handle = try FileHandle(forWritingTo: url)
        }

        func write(_ text: String) {
            let data = Data(text.utf8)
            buffer.append(data)
            bytes += data.count
            if buffer.count >= 1 << 20, failure == nil {
                do { try flush() } catch { failure = error }
            }
        }

        func flush() throws {
            guard !buffer.isEmpty else { return }
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }

        func close() throws {
            defer { try? handle.close() }
            if let failure { throw failure }
            try flush()
        }
    }
}
