import Foundation
import MCP
import SQCore

/// What the MCP tools need from the app: saved connections, their passwords, the user's approval for
/// production writes, and somewhere to record what the AI did.
public protocol MCPProvider: Sendable {
    func profiles() async -> [ConnectionProfile]
    /// The password for `profile.effectiveMCPUser`: the separate AI login if there is one, else the connection's.
    func password(for profile: ConnectionProfile) async -> String?
    /// Asked before a write on a production (red) connection. `false` blocks it.
    func approveWrite(_ sql: String, on profile: ConnectionProfile) async -> Bool
    func record(_ activity: MCPActivity) async
}

/// One tool call, for the app's activity log.
public struct MCPActivity: Identifiable, Sendable {
    public enum Outcome: Sendable {
        case success(String)
        case blocked(String)
        case failed(String)
    }

    public let id = UUID()
    public let time = Date()
    public let tool: String
    public let connectionID: UUID
    public let connection: String?
    public let sql: String?
    public let outcome: Outcome
    public let duration: Duration?
}

/// The MCP tools for one saved connection: connection_info, list_databases, list_tables, describe_table,
/// run_query, export_sql, and the writes execute, drop_tables, truncate_tables and import_sql. Every call opens its own short-lived MySQL connection, so AI calls never touch the
/// user's open tabs.
public struct SQLTools: Sendable {
    public static let defaultRowCap = 200
    public static let maxRowCap = 500

    let provider: any MCPProvider
    let connectionID: UUID

    public init(provider: any MCPProvider, connection: UUID) {
        self.provider = provider
        self.connectionID = connection
    }

    /// A fresh `Server` with the tools registered, one per MCP session.
    public func makeServer(version: String) async -> Server {
        let server = Server(
            name: "query-pro",
            version: version,
            instructions: """
                Access to one MySQL connection the user saved in Query Pro. Start with connection_info, then \
                list_databases / list_tables / describe_table to learn the schema before querying. run_query and \
                export_sql only read. execute, drop_tables, truncate_tables and import_sql change things and only work if the user \
                allowed writes for this connection.
                """,
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: Self.definitions)
        }
        await server.withMethodHandler(CallTool.self) { params in
            await call(params.name, arguments: params.arguments ?? [:])
        }
        return server
    }

    // MARK: Definitions

    static let definitions: [Tool] = [
        Tool(
            name: "connection_info",
            description: "The MySQL connection this server is for: name, host, user, default database and access level (read_only or read_write).",
            inputSchema: schema([:]),
            annotations: .init(readOnlyHint: true)
        ),
        Tool(
            name: "list_databases",
            description: "List the databases (schemas) this connection can see.",
            inputSchema: schema([:]),
            annotations: .init(readOnlyHint: true)
        ),
        Tool(
            name: "list_tables",
            description: "List tables and views in a database, with approximate row counts and comments.",
            inputSchema: schema(["database": databaseProperty], required: ["database"]),
            annotations: .init(readOnlyHint: true)
        ),
        Tool(
            name: "describe_table",
            description: "Columns, indexes, foreign keys and the CREATE TABLE statement of one table.",
            inputSchema: schema(
                ["database": databaseProperty, "table": .object(["type": "string", "description": "Table name"])],
                required: ["database", "table"]
            ),
            annotations: .init(readOnlyHint: true)
        ),
        Tool(
            name: "run_query",
            description: """
                Run one read-only statement (SELECT, SHOW, DESCRIBE, EXPLAIN) and get the rows as JSON. \
                Results are capped at max_rows (default \(defaultRowCap), at most \(maxRowCap)); the query is stopped after 30 seconds.
                """,
            inputSchema: schema(
                [
                    "sql": .object(["type": "string", "description": "A single read-only SQL statement"]),
                    "database": .object(["type": "string", "description": "Database to run it in (optional)"]),
                    "max_rows": .object(["type": "integer", "description": "Row cap, 1–\(maxRowCap)"]),
                ],
                required: ["sql"]
            ),
            annotations: .init(readOnlyHint: true)
        ),
        Tool(
            name: "execute",
            description: """
                Run one statement that changes data or schema (INSERT, UPDATE, DELETE, CREATE, ALTER…). Only works when \
                the connection has read_write access; production connections ask the user first.
                """,
            inputSchema: schema(
                [
                    "sql": .object(["type": "string", "description": "A single SQL statement"]),
                    "database": .object(["type": "string", "description": "Database to run it in (optional)"]),
                ],
                required: ["sql"]
            ),
            annotations: .init(readOnlyHint: false, destructiveHint: true)
        ),
        Tool(
            name: "export_sql",
            description: """
                Export a database to a .sql dump file on this Mac, like mysqldump: content structure_and_data, structure_only or \
                data_only, for every table or the ones named in tables. With structure and every table, views, routines and \
                triggers are included (include_objects false leaves them out). Read from one consistent snapshot. The file \
                imports back with import_sql (or the mysql client), into a database of any name. An existing file is only \
                replaced with overwrite true.
                """,
            inputSchema: schema(
                [
                    "database": databaseProperty,
                    "content": .object([
                        "type": "string", "enum": .array(SQLDumpExport.Content.allCases.map { .string($0.rawValue) }),
                        "description": "structure_and_data, structure_only or data_only",
                    ]),
                    "path": .object(["type": "string", "description": "Absolute path of the .sql file to write"]),
                    "tables": tablesProperty,
                    "include_objects": .object(["type": "boolean", "description": "Views, routines and triggers (default true)"]),
                    "overwrite": .object(["type": "boolean", "description": "Replace the file if it exists (default false)"]),
                ],
                required: ["database", "content", "path"]
            ),
            annotations: .init(readOnlyHint: true)
        ),
        Tool(
            name: "drop_tables",
            description: """
                Drop tables of a database: the ones named in tables, or every table when tables is left out. Views and \
                routines stay. Foreign key checks are off while dropping. Needs read_write access; production connections \
                ask the user first.
                """,
            inputSchema: schema(["database": databaseProperty, "tables": tablesProperty], required: ["database"]),
            annotations: .init(readOnlyHint: false, destructiveHint: true)
        ),
        Tool(
            name: "truncate_tables",
            description: """
                Delete every row of tables of a database (TRUNCATE: AUTO_INCREMENT restarts), keeping the tables: the ones \
                named in tables, or every table when tables is left out. Needs read_write access; production connections \
                ask the user first.
                """,
            inputSchema: schema(["database": databaseProperty, "tables": tablesProperty], required: ["database"]),
            annotations: .init(readOnlyHint: false, destructiveHint: true)
        ),
        Tool(
            name: "import_sql",
            description: """
                Import a SQL dump (e.g. from mysqldump) into a database, from a local .sql file (path) or from text (sql). \
                mode structure_and_data runs every statement: tables are created (or replaced, if the dump drops them) and \
                filled; it stops at the first error and DDL already run stays. mode data_only runs only INSERT / REPLACE / \
                UPDATE / DELETE (and SET / USE) into existing tables (their triggers fire), in one transaction that rolls back on \
                any error. \
                Foreign key checks are off during the import. A USE in the dump wins over database. Needs read_write \
                access; production connections ask the user first.
                """,
            inputSchema: schema(
                [
                    "database": .object(["type": "string", "description": "Database to import into (optional if the dump has its own USE)"]),
                    "mode": .object([
                        "type": "string", "enum": .array(SQLDump.Mode.allCases.map { .string($0.rawValue) }),
                        "description": "structure_and_data (tables and rows) or data_only (rows into existing tables)",
                    ]),
                    "path": .object(["type": "string", "description": "Absolute path of a .sql file on this Mac"]),
                    "sql": .object(["type": "string", "description": "The dump's text, instead of path"]),
                ],
                required: ["mode"]
            ),
            annotations: .init(readOnlyHint: false, destructiveHint: true)
        ),
    ]

    private static let databaseProperty: Value = .object(["type": "string", "description": "Database (schema) name"])
    private static let tablesProperty: Value = .object([
        "type": "array", "items": .object(["type": "string"]),
        "description": "Table names; leave out for every table in the database",
    ])

    private static func schema(_ properties: [String: Value], required: [String] = []) -> Value {
        .object([
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
        ])
    }

    // MARK: Calls

    func call(_ tool: String, arguments: [String: Value]) async -> CallTool.Result {
        let clock = ContinuousClock()
        let start = clock.now
        let connection = await provider.profiles().first { $0.id == connectionID }?.name
        let sql = Self.loggedSQL(tool, arguments)
        do {
            let (text, summary) = try await perform(tool, arguments: arguments)
            await provider.record(MCPActivity(tool: tool, connectionID: connectionID, connection: connection, sql: sql, outcome: .success(summary), duration: clock.now - start))
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch let error as ToolError {
            await provider.record(MCPActivity(
                tool: tool, connectionID: connectionID, connection: connection, sql: sql,
                outcome: error.isBlock ? .blocked(error.message) : .failed(error.message), duration: clock.now - start
            ))
            return .init(content: [.text(text: error.message, annotations: nil, _meta: nil)], isError: true)
        } catch {
            let message = ErrorText.message(for: error)
            await provider.record(MCPActivity(tool: tool, connectionID: connectionID, connection: connection, sql: sql, outcome: .failed(message), duration: clock.now - start))
            return .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
        }
    }

    /// Returns the tool's text output and a one-line summary for the activity log.
    private func perform(_ tool: String, arguments: [String: Value]) async throws -> (String, String) {
        switch tool {
        case "connection_info":
            let profile = try await profile(arguments)
            let info: [String: Any] = [
                "name": profile.name,
                "group": profile.groupName ?? "",
                "host": profile.address,
                "user": profile.effectiveMCPUser,
                "default_database": profile.defaultSchema,
                "access": profile.mcpAccess == .readWrite ? "read_write" : "read_only",
                "production": profile.color.isProduction,
            ]
            return (try json(info), profile.name)

        case "list_databases":
            let profile = try await profile(arguments)
            let rows = Self.asAI(profile).visibleSchemas(try await run(profile, database: nil, "SHOW DATABASES").rows.compactMap { $0.first ?? nil })
            return (try json(rows), "\(rows.count) database(s)")

        case "list_tables":
            let profile = try await profile(arguments)
            let database = try required("database", arguments)
            let result = try await run(profile, database: nil, """
                SELECT TABLE_NAME, TABLE_TYPE, TABLE_ROWS, TABLE_COMMENT FROM information_schema.TABLES
                WHERE TABLE_SCHEMA = \(SQL.quoteString(database)) ORDER BY TABLE_NAME
                """)
            let tables = result.rows.map { row -> [String: Any] in
                [
                    "name": row[0] ?? "",
                    "type": row[1] == "VIEW" ? "view" : "table",
                    "approx_rows": row[2].flatMap(Int.init) as Any? ?? NSNull(),
                    "comment": row[3] ?? "",
                ]
            }
            return (try json(tables), "\(tables.count) table(s) in \(database)")

        case "describe_table":
            let profile = try await profile(arguments)
            let database = try required("database", arguments)
            let table = try required("table", arguments)
            let session = try await open(profile, database: nil)
            defer { Task { await session.close() } }
            let (s, t) = (SQL.quoteString(database), SQL.quoteString(table))
            let columns = try await session.execute("""
                SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY, COLUMN_DEFAULT, EXTRA, COLUMN_COMMENT
                FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = \(s) AND TABLE_NAME = \(t) ORDER BY ORDINAL_POSITION
                """)
            guard !columns.rows.isEmpty else { throw ToolError("Table \(database).\(table) not found.") }
            let indexes = try await session.execute("""
                SELECT INDEX_NAME, NON_UNIQUE, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX)
                FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = \(s) AND TABLE_NAME = \(t)
                GROUP BY INDEX_NAME, NON_UNIQUE ORDER BY INDEX_NAME = 'PRIMARY' DESC, INDEX_NAME
                """)
            let foreignKeys = try await session.execute("""
                SELECT CONSTRAINT_NAME, GROUP_CONCAT(COLUMN_NAME ORDER BY ORDINAL_POSITION),
                       REFERENCED_TABLE_SCHEMA, REFERENCED_TABLE_NAME, GROUP_CONCAT(REFERENCED_COLUMN_NAME ORDER BY ORDINAL_POSITION)
                FROM information_schema.KEY_COLUMN_USAGE
                WHERE TABLE_SCHEMA = \(s) AND TABLE_NAME = \(t) AND REFERENCED_TABLE_NAME IS NOT NULL
                GROUP BY CONSTRAINT_NAME, REFERENCED_TABLE_SCHEMA, REFERENCED_TABLE_NAME
                """)
            let ddl = try await session.execute("SHOW CREATE TABLE \(SQL.quoteIdentifier(database)).\(SQL.quoteIdentifier(table))")
            let description: [String: Any] = [
                "columns": columns.rows.map { row in
                    [
                        "name": row[0] ?? "", "type": row[1] ?? "", "nullable": row[2] == "YES", "key": row[3] ?? "",
                        "default": row[4] as Any? ?? NSNull(), "extra": row[5] ?? "", "comment": row[6] ?? "",
                    ] as [String: Any]
                },
                "indexes": indexes.rows.map { row in
                    ["name": row[0] ?? "", "unique": row[1] == "0", "columns": (row[2] ?? "").split(separator: ",").map(String.init)] as [String: Any]
                },
                "foreign_keys": foreignKeys.rows.map { row in
                    [
                        "name": row[0] ?? "", "columns": (row[1] ?? "").split(separator: ",").map(String.init),
                        "references": "\(row[2] ?? "").\(row[3] ?? "")", "referenced_columns": (row[4] ?? "").split(separator: ",").map(String.init),
                    ] as [String: Any]
                },
                "create_table": ddl.rows.first.flatMap { $0.count > 1 ? $0[1] : nil } ?? "",
            ]
            return (try json(description), "\(columns.rows.count) column(s)")

        case "run_query":
            let profile = try await profile(arguments)
            let sql = try required("sql", arguments)
            guard SQL.isReadOnly(sql) else {
                throw ToolError(
                    "run_query only runs a single SELECT, SHOW, DESCRIBE or EXPLAIN statement. Use execute for changes.",
                    isBlock: true
                )
            }
            let cap = min(max(arguments["max_rows"]?.intValue ?? Self.defaultRowCap, 1), Self.maxRowCap)
            let statement = SQL.statements(in: sql).first?.text ?? sql
            // Ask for one row more than the cap to know whether there was more.
            let (limited, _) = SQL.applyingLimit(cap + 1, to: statement)
            let session = try await open(profile, database: arguments["database"]?.stringValue)
            defer { Task { await session.close() } }
            _ = try await session.execute("SET SESSION MAX_EXECUTION_TIME = 30000")
            // A read-only transaction is a second guard: the server itself refuses writes inside it.
            _ = try await session.execute("START TRANSACTION READ ONLY")
            let result = try await session.execute(limited)
            _ = try? await session.execute("COMMIT")
            let truncated = result.rows.count > cap
            let rows = Array(result.rows.prefix(cap))
            let output: [String: Any] = [
                "columns": result.columns.map(\.name),
                "rows": rows.map { $0.map { $0 as Any? ?? NSNull() } },
                "row_count": rows.count,
                "truncated": truncated,
            ]
            return (try json(output), "\(rows.count) row(s)\(truncated ? " (truncated)" : "")")

        case "execute":
            let profile = try await profile(arguments)
            let sql = try required("sql", arguments)
            try requireWrites(profile)
            let statements = SQL.statements(in: sql)
            guard statements.count == 1, let statement = statements.first?.text else {
                throw ToolError("execute runs exactly one statement; send them one at a time.", isBlock: true)
            }
            if profile.color.isProduction, !(await provider.approveWrite(statement, on: profile)) {
                throw ToolError("The user declined this change on production connection \(profile.name).", isBlock: true)
            }
            let result = try await run(profile, database: arguments["database"]?.stringValue, statement)
            var output: [String: Any] = ["affected_rows": result.affectedRows]
            if let id = result.lastInsertID, id > 0 { output["last_insert_id"] = id }
            if !result.info.isEmpty { output["info"] = result.info }
            if result.hasResultSet { output["rows_returned"] = result.rows.count }
            return (try json(output), result.summary)

        case "export_sql":
            let profile = try await profile(arguments)
            let database = try required("database", arguments)
            guard let content = arguments["content"]?.stringValue.flatMap(SQLDumpExport.Content.init(rawValue:)) else {
                throw ToolError("content must be structure_and_data, structure_only or data_only.")
            }
            let url = try dumpURL(try required("path", arguments))
            guard arguments["overwrite"]?.boolValue == true || !FileManager.default.fileExists(atPath: url.path) else {
                throw ToolError("\(url.path) already exists. Pass overwrite true to replace it.", isBlock: true)
            }
            var options = SQLDumpExport.Options(content: content, tables: arguments["tables"]?.arrayValue?.compactMap(\.stringValue))
            options.includesObjects = arguments["include_objects"]?.boolValue ?? true
            let session = try await open(profile, database: nil)
            defer { Task { await session.close() } }
            let outcome: SQLDumpExport.Outcome
            do {
                outcome = try await SQLDumpExport.run(schema: database, options: options, on: session, to: url, server: profile.address)
            } catch let error as SQLDumpExport.ExportError {
                throw ToolError(error.message)
            }
            let output: [String: Any] = [
                "path": url.path, "tables": outcome.tables, "views": outcome.views, "routines": outcome.routines,
                "triggers": outcome.triggers, "rows": outcome.rows, "bytes": outcome.bytes,
            ]
            return (try json(output), "Exported \(database) (\(content.title)) to \(url.lastPathComponent): \(outcome.summary)")

        case "drop_tables", "truncate_tables":
            let profile = try await profile(arguments)
            let database = try required("database", arguments)
            try requireWrites(profile)
            guard !SchemaScript.isSystem(database) else {
                throw ToolError("\(database) is a system database; its tables can't be dropped or emptied here.", isBlock: true)
            }
            let isDrop = tool == "drop_tables"
            let session = try await open(profile, database: nil)
            defer { Task { await session.close() } }
            let existing = try await session.execute(SchemaScript.tablesQuery(database)).rows.compactMap { $0.first ?? nil }
            var tables = existing
            if let named = arguments["tables"]?.arrayValue {
                tables = named.compactMap(\.stringValue)
                let unknown = tables.filter { !existing.contains($0) }
                guard unknown.isEmpty else {
                    throw ToolError("No table \(unknown.joined(separator: ", ")) in \(database). Views can't be dropped or emptied with this tool.")
                }
            }
            guard !tables.isEmpty else { throw ToolError("\(database) has no tables.") }
            let statements = isDrop ? SchemaScript.dropTables(tables, in: database) : SchemaScript.truncateTables(tables, in: database)
            let what = tables == existing ? "all \(tables.count) table(s) in \(database)" : "\(tables.count) table(s) in \(database)"
            if profile.color.isProduction, !(await provider.approveWrite(SchemaScript.text(statements), on: profile)) {
                throw ToolError("The user declined to \(isDrop ? "drop" : "empty") \(what) on production connection \(profile.name).", isBlock: true)
            }
            var done: [String] = []
            for (index, statement) in statements.enumerated() {
                do {
                    _ = try await session.execute(statement)
                } catch {
                    let table = index > 0 && index <= tables.count ? tables[index - 1] : nil
                    throw ToolError("""
                        \(ErrorText.message(for: error))\(table.map { " (table \($0))" } ?? "").\
                        \(done.isEmpty ? "" : " Already \(isDrop ? "dropped" : "emptied"): \(done.joined(separator: ", ")).")
                        """)
                }
                if index > 0, index <= tables.count { done.append(tables[index - 1]) }
            }
            let output: [String: Any] = [isDrop ? "dropped" : "truncated": done]
            return (try json(output), "\(isDrop ? "Dropped" : "Emptied") \(what)")

        case "import_sql":
            let profile = try await profile(arguments)
            try requireWrites(profile)
            guard let mode = arguments["mode"]?.stringValue.flatMap(SQLDump.Mode.init(rawValue:)) else {
                throw ToolError("mode must be structure_and_data or data_only.")
            }
            let (text, source) = try readDump(arguments)
            let database = arguments["database"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let plan = SQLDump.plan(SQLDump.statements(in: text), mode: mode)
            guard !plan.statements.isEmpty else {
                throw ToolError(mode == .dataOnly && plan.skipped > 0
                    ? "The dump has no data statements (INSERT, REPLACE, UPDATE, DELETE) to import."
                    : "The dump has no statements.")
            }
            let target = database.isEmpty ? "" : " into \(database)"
            let description = "Import \(source) (\(mode == .dataOnly ? "data only" : "structure and data"))\(target): "
                + "\(plan.statements.count) statement(s), \(plan.tablesCreated) CREATE TABLE, \(plan.dataStatements) data statement(s)"
                + (plan.schemasNamed.isEmpty ? "" : "; the dump itself switches to \(plan.schemasNamed.joined(separator: ", "))")
            if profile.color.isProduction, !(await provider.approveWrite(description, on: profile)) {
                throw ToolError("The user declined this import on production connection \(profile.name).", isBlock: true)
            }
            let session = try await open(profile, database: nil)
            defer { Task { await session.close() } }
            let outcome: SQLDumpImport.Outcome
            do {
                outcome = try await SQLDumpImport.run(plan, mode: mode, schema: database, on: session)
            } catch let failure as SQLDumpImport.Failure {
                throw ToolError(failure.errorDescription ?? failure.message)
            }
            let output: [String: Any] = [
                "statements_run": outcome.statements,
                "skipped": plan.skipped,
                "tables_created": plan.tablesCreated,
                "affected_rows": outcome.affectedRows,
            ]
            return (try json(output), "\(outcome.statements) statement(s), \(outcome.affectedRows) row(s) affected")

        default:
            throw ToolError("Unknown tool \(tool).")
        }
    }

    // MARK: Helpers

    /// The connection this server is for, as currently saved. Fails if it was deleted or hidden from AI.
    private func profile(_ arguments: [String: Value]) async throws -> ConnectionProfile {
        guard let profile = await provider.profiles().first(where: { $0.id == connectionID }), profile.mcpAccess != .hidden else {
            throw ToolError("This connection is no longer available to AI clients in Query Pro.", isBlock: true)
        }
        return profile
    }

    private func requireWrites(_ profile: ConnectionProfile) throws {
        guard profile.mcpAccess == .readWrite else {
            throw ToolError(
                "\(profile.name) is read-only for AI. The user can allow writes in Query Pro: Edit Connection › AI access.",
                isBlock: true
            )
        }
    }

    /// The dump's text and how to name it. A path must be an absolute `.sql` file, so the tool can't be
    /// pointed at arbitrary files.
    private func readDump(_ arguments: [String: Value]) throws -> (text: String, source: String) {
        let path = arguments["path"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let sql = arguments["sql"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        switch (path, sql) {
        case (let path?, nil):
            let url = try dumpURL(path)
            do {
                return (try CSV.read(url), url.lastPathComponent)
            } catch {
                throw ToolError("Can't read \(url.path): \(error.localizedDescription)")
            }
        case (nil, let sql?):
            return (sql, "SQL text")
        default:
            throw ToolError("Give path or sql: one of them.")
        }
    }

    /// Dumps are read from and written to absolute `.sql` paths only, so the tools can't touch other files.
    private func dumpURL(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard path.hasPrefix("/") || path.hasPrefix("~"), url.pathExtension.lowercased() == "sql" else {
            throw ToolError("path must be the absolute path of a .sql file.", isBlock: true)
        }
        return url
    }

    /// What the activity log shows as the SQL: dumps are summarised, not copied in.
    static func loggedSQL(_ tool: String, _ arguments: [String: Value]) -> String? {
        switch tool {
        case "drop_tables", "truncate_tables":
            let database = arguments["database"]?.stringValue ?? ""
            let tables = arguments["tables"]?.arrayValue?.compactMap(\.stringValue)
            let list = tables.map { $0.map(SQL.quoteIdentifier).joined(separator: ", ") } ?? "all tables"
            return "\(tool == "drop_tables" ? "DROP" : "TRUNCATE") TABLE \(list) in \(SQL.quoteIdentifier(database))"
        case "export_sql":
            let content = arguments["content"]?.stringValue ?? ""
            let database = arguments["database"]?.stringValue ?? ""
            return "-- Export \(SQL.quoteIdentifier(database)) (\(content)) to \(arguments["path"]?.stringValue ?? "?")"
        case "import_sql":
            let mode = arguments["mode"]?.stringValue ?? ""
            let source = arguments["path"]?.stringValue ?? "\(arguments["sql"]?.stringValue?.count ?? 0) characters of SQL"
            let database = arguments["database"]?.stringValue.map { " into \(SQL.quoteIdentifier($0))" } ?? ""
            return "-- Import \(source) (\(mode))\(database)"
        default:
            return arguments["sql"]?.stringValue
        }
    }

    private func required(_ key: String, _ arguments: [String: Value]) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError("Missing \(key).")
        }
        return value
    }

    /// The profile as AI clients see it: logged in as the separate AI user when there is one.
    static func asAI(_ profile: ConnectionProfile) -> ConnectionProfile {
        var target = profile
        target.user = profile.effectiveMCPUser
        return target
    }

    private func open(_ profile: ConnectionProfile, database: String?) async throws -> MySQLSession {
        var target = Self.asAI(profile)
        if let database, !database.isEmpty { target.defaultSchema = database }
        let session = MySQLSession(profile: target, password: await provider.password(for: profile))
        try await session.connect()
        return session
    }

    private func run(_ profile: ConnectionProfile, database: String?, _ sql: String) async throws -> QueryResult {
        let session = try await open(profile, database: database)
        defer { Task { await session.close() } }
        return try await session.execute(sql)
    }

    private func json(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}

struct ToolError: Error {
    let message: String
    /// Refused on purpose (permissions, read-only), as opposed to failing.
    let isBlock: Bool

    init(_ message: String, isBlock: Bool = false) {
        self.message = message
        self.isBlock = isBlock
    }
}
