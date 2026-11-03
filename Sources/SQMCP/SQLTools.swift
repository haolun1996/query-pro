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
/// run_query, execute. Every call opens its own short-lived MySQL connection, so AI calls never touch the
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
                list_databases / list_tables / describe_table to learn the schema before querying. run_query is \
                read-only; execute is for writes and only works if the user allowed writes for this connection.
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
    ]

    private static let databaseProperty: Value = .object(["type": "string", "description": "Database (schema) name"])

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
        let sql = arguments["sql"]?.stringValue
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
            guard profile.mcpAccess == .readWrite else {
                throw ToolError(
                    "\(profile.name) is read-only for AI. The user can allow writes in Query Pro: Edit Connection › AI access.",
                    isBlock: true
                )
            }
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
