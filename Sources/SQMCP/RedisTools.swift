import Foundation
import MCP
import SQCore

/// The MCP tools for one saved Redis connection: connection_info, server_info, scan_keys, get_key, run_command
/// (read-only commands) and execute_command (writes, only if allowed). Like `SQLTools`, every call opens its own
/// short-lived connection as the AI user, so AI calls never touch the user's open tabs.
public struct RedisTools: Sendable {
    public static let defaultLimit = 200
    public static let maxLimit = 1000

    let provider: any MCPProvider
    let connectionID: UUID

    public init(provider: any MCPProvider, connection: UUID) {
        self.provider = provider
        self.connectionID = connection
    }

    public func makeServer(version: String) async -> Server {
        let server = Server(
            name: "query-pro",
            version: version,
            instructions: """
                Access to one Redis connection the user saved in Query Pro. Start with connection_info and server_info, \
                find keys with scan_keys (never KEYS), read them with get_key. run_command runs one read-only command. \
                execute_command changes data and only works if the user allowed writes for this connection. \
                Administration (FLUSHALL, CONFIG, ACL, SHUTDOWN…), scripts, transactions and blocking commands are never allowed.
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

    private static let databaseProperty: Value = .object([
        "type": "integer", "description": "Database number (SELECT); leave out for the connection's default",
    ])
    private static let commandProperties: [String: Value] = [
        "command": .object(["type": "string", "description": #"One command in redis-cli syntax, e.g. HGETALL "user:42""#]),
        "args": .object([
            "type": "array", "items": .object(["type": "string"]),
            "description": "The same command as separate arguments, e.g. [\"HGETALL\", \"user:42\"]; use instead of command for values with quotes or spaces",
        ]),
        "database": databaseProperty,
    ]

    static let definitions: [Tool] = [
        Tool(
            name: "connection_info",
            description: "The Redis connection this server is for: name, host, user, default database, TLS and access level (read_only or read_write).",
            inputSchema: schema([:]),
            annotations: .init(readOnlyHint: true)
        ),
        Tool(
            name: "server_info",
            description: "Redis version, mode, role, memory use, and keys per database.",
            inputSchema: schema([:]),
            annotations: .init(readOnlyHint: true)
        ),
        Tool(
            name: "scan_keys",
            description: """
                Find keys with SCAN (never blocks the server): a glob pattern such as user:* , optionally one type \
                (string, hash, list, set, zset, stream). Returns each key's type and TTL in milliseconds (null = no expiry), \
                up to limit keys (default \(defaultLimit), at most \(maxLimit)). If cursor in the reply isn't "0", pass it \
                back to continue.
                """,
            inputSchema: schema([
                "pattern": .object(["type": "string", "description": "Glob pattern, default *"]),
                "type": .object(["type": "string", "description": "Only keys of this type"]),
                "cursor": .object(["type": "string", "description": "From a previous call, to continue"]),
                "limit": .object(["type": "integer", "description": "Most keys to return, 1–\(maxLimit)"]),
                "database": databaseProperty,
            ]),
            annotations: .init(readOnlyHint: true)
        ),
        Tool(
            name: "get_key",
            description: """
                One key's type, TTL and value: a string as text; a hash as an object; a list, set or sorted set as an \
                array (sorted sets as {member, score}); a stream as its newest entries. Collections are capped at limit \
                (default \(defaultLimit), at most \(maxLimit)); total says how many there are. Binary data is escaped like \
                redis-cli (\\xHH) and flagged binary.
                """,
            inputSchema: schema(
                [
                    "key": .object(["type": "string", "description": "Key name"]),
                    "limit": .object(["type": "integer", "description": "Most elements to return, 1–\(maxLimit)"]),
                    "database": databaseProperty,
                ],
                required: ["key"]
            ),
            annotations: .init(readOnlyHint: true)
        ),
        Tool(
            name: "run_command",
            description: """
                Run one read-only Redis command (GET, HGETALL, LRANGE, ZRANGE, XRANGE, TTL, TYPE, MEMORY USAGE, \
                OBJECT ENCODING, INFO…) and get the reply as JSON. Commands that write, administer the server, block, \
                or scan every key (KEYS) are refused; use scan_keys to find keys.
                """,
            inputSchema: schema(commandProperties),
            annotations: .init(readOnlyHint: true)
        ),
        Tool(
            name: "execute_command",
            description: """
                Run one Redis command that changes data (SET, HSET, DEL, EXPIRE, LPUSH, ZADD, XADD…). Only works when the \
                connection has read_write access; production connections ask the user first. Server administration \
                (FLUSHALL, FLUSHDB, CONFIG, ACL, SHUTDOWN…), scripts, transactions and blocking commands are never allowed.
                """,
            inputSchema: schema(commandProperties),
            annotations: .init(readOnlyHint: false, destructiveHint: true)
        ),
    ]

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
        let logged = Self.loggedCommand(tool, arguments)
        func record(_ outcome: MCPActivity.Outcome) async {
            await provider.record(MCPActivity(
                tool: tool, connectionID: connectionID, connection: connection, sql: logged, outcome: outcome, duration: clock.now - start
            ))
        }
        do {
            let (text, summary) = try await perform(tool, arguments: arguments)
            await record(.success(summary))
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch let error as ToolError {
            await record(error.isBlock ? .blocked(error.message) : .failed(error.message))
            return .init(content: [.text(text: error.message, annotations: nil, _meta: nil)], isError: true)
        } catch {
            let message = ErrorText.message(for: error)
            await record(.failed(message))
            return .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
        }
    }

    private func perform(_ tool: String, arguments: [String: Value]) async throws -> (String, String) {
        let profile = try await profile()
        switch tool {
        case "connection_info":
            let info: [String: Any] = [
                "name": profile.name,
                "group": profile.groupName ?? "",
                "kind": "redis",
                "host": profile.address,
                "user": profile.effectiveMCPUser.isEmpty ? "default" : profile.effectiveMCPUser,
                "default_database": profile.redisDatabase,
                "tls": profile.sslMode == .required,
                "access": profile.mcpAccess == .readWrite ? "read_write" : "read_only",
                "production": profile.color.isProduction,
            ]
            return (try json(info), profile.name)

        case "server_info":
            let session = try await open(profile, database: nil)
            defer { Task { await session.close() } }
            let info = try await session.call("INFO").string ?? ""
            var output: [String: Any] = [:]
            for field in ["redis_version", "valkey_version", "redis_mode", "role", "used_memory_human", "maxmemory_human",
                          "maxmemory_policy", "connected_clients", "uptime_in_days"] {
                if let value = RedisBrowser.infoField(field, in: info) { output[field] = value }
            }
            output["keys_per_database"] = Dictionary(uniqueKeysWithValues: RedisBrowser.keyspace(info).map { ("db\($0.key)", $0.value) })
            return (try json(output), "Redis \(output["redis_version"] ?? "")")

        case "scan_keys":
            let session = try await open(profile, database: database(arguments))
            defer { Task { await session.close() } }
            let limit = Self.limit(arguments)
            let pattern = arguments["pattern"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "*"
            let type = arguments["type"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            var cursor = arguments["cursor"]?.stringValue ?? "0"
            var names: [Data] = []
            var seen: Set<Data> = []
            // Bounded, so a pattern matching almost nothing in a huge keyspace can't loop for minutes.
            var steps = 0
            repeat {
                let step = try await RedisBrowser.scan(session, cursor: cursor, pattern: pattern, count: 1000, type: type)
                cursor = step.cursor
                for name in step.keys where seen.insert(name).inserted { names.append(name) }
                steps += 1
            } while cursor != "0" && names.count < limit && steps < 200
            let keys = try await RedisBrowser.describe(session, Array(names.prefix(limit)))
            let output: [String: Any] = [
                "keys": keys.map { key -> [String: Any] in
                    var item: [String: Any] = ["key": key.displayName, "type": key.type, "ttl_ms": key.ttl as Any? ?? NSNull()]
                    if RedisCommand.isBinary(key.name) { item["binary"] = true }
                    return item
                },
                "cursor": names.count > limit ? "more matched than limit; scan again with a larger limit or a narrower pattern" : cursor,
            ]
            return (try json(output), "\(keys.count) key(s) matching \(pattern)")

        case "get_key":
            let name = try required("key", arguments)
            let session = try await open(profile, database: database(arguments))
            defer { Task { await session.close() } }
            let key = Data(name.utf8)
            guard let described = try await RedisBrowser.describe(session, [key]).first else {
                throw ToolError("Key \(name) doesn't exist in this database.")
            }
            let loaded = try await RedisBrowser.load(session, key: key, type: described.type, limit: Self.limit(arguments))
            var output: [String: Any] = [
                "key": name, "type": described.type, "ttl_ms": described.ttl as Any? ?? NSNull(), "total": loaded.total,
                "truncated": loaded.isTruncated,
            ]
            var binary = false
            func text(_ data: Data) -> String {
                if RedisCommand.isBinary(data) { binary = true }
                return RedisCommand.display(data)
            }
            switch loaded.value {
            case .string(let data): output["value"] = RedisCommand.isBinary(data) ? text(data) : String(decoding: data, as: UTF8.self)
            case .hash(let pairs): output["value"] = Dictionary(pairs.map { (text($0.field), text($0.value)) }, uniquingKeysWith: { a, _ in a })
            case .list(let items), .set(let items): output["value"] = items.map(text)
            case .zset(let items): output["value"] = items.map { ["member": text($0.member), "score": Double($0.score) ?? 0] as [String: Any] }
            case .stream(let entries):
                output["value"] = entries.map { entry in
                    ["id": entry.id, "fields": Dictionary(entry.fields.map { (text($0.0), text($0.1)) }, uniquingKeysWith: { a, _ in a })] as [String: Any]
                }
            case .other(let type):
                output["value"] = NSNull()
                output["note"] = "Query Pro has no reader for \(type); try run_command with the module's read command (e.g. JSON.GET)."
            }
            if binary { output["binary"] = true }
            return (try json(output), "\(described.type) \(name)")

        case "run_command", "execute_command":
            let words = try command(arguments)
            let texts = words.map { String(decoding: $0, as: UTF8.self) }
            let access = RedisCommand.access(texts)
            if case .refused(let reason) = access { throw ToolError(reason, isBlock: true) }
            if tool == "run_command", access != .read {
                throw ToolError(
                    "\(texts[0].uppercased()) isn't a read-only command. Use execute_command for changes (if this connection allows them).",
                    isBlock: true
                )
            }
            if tool == "execute_command" {
                guard profile.mcpAccess == .readWrite else {
                    throw ToolError(
                        "\(profile.name) is read-only for AI. The user can allow writes in Query Pro: Edit Connection › AI access.",
                        isBlock: true
                    )
                }
                let shown = words.map(RedisCommand.quote).joined(separator: " ")
                if profile.color.isProduction, !(await provider.approveWrite(shown, on: profile)) {
                    throw ToolError("The user declined this change on production connection \(profile.name).", isBlock: true)
                }
            }
            let session = try await open(profile, database: database(arguments))
            defer { Task { await session.close() } }
            let reply = try await session.send(words)
            if case .error(let message) = reply { throw ToolError(message) }
            return (try json(["reply": Self.jsonValue(reply)]), Self.summary(reply))

        default:
            throw ToolError("Unknown tool \(tool).")
        }
    }

    // MARK: Helpers

    private func profile() async throws -> ConnectionProfile {
        guard let profile = await provider.profiles().first(where: { $0.id == connectionID }), profile.mcpAccess != .hidden else {
            throw ToolError("This connection is no longer available to AI clients in Query Pro.", isBlock: true)
        }
        return profile
    }

    private func open(_ profile: ConnectionProfile, database: Int?) async throws -> RedisSession {
        var target = SQLTools.asAI(profile)
        if let database { target.redisDatabase = database }
        let session = RedisSession(profile: target, password: await provider.password(for: profile), connectTimeout: .seconds(10))
        try await session.connect()
        return session
    }

    private func database(_ arguments: [String: Value]) throws -> Int? {
        guard let value = arguments["database"] else { return nil }
        if let number = value.intValue, number >= 0 { return number }
        if let text = value.stringValue, let number = Int(text), number >= 0 { return number }
        throw ToolError("database must be a number, e.g. 0.")
    }

    private func command(_ arguments: [String: Value]) throws -> [Data] {
        if let args = arguments["args"]?.arrayValue {
            let words = args.compactMap(\.stringValue)
            guard !words.isEmpty, words.count == args.count else { throw ToolError("args must be a non-empty array of strings.") }
            return words.map { Data($0.utf8) }
        }
        let line = try required("command", arguments)
        do {
            let words = try RedisCommand.parse(line)
            guard !words.isEmpty else { throw ToolError("Missing command.") }
            return words
        } catch let error as RedisCommand.SyntaxError {
            throw ToolError(error.localizedDescription)
        }
    }

    private static func limit(_ arguments: [String: Value]) -> Int {
        let requested = arguments["limit"]?.intValue ?? defaultLimit
        return min(max(requested, 1), maxLimit)
    }

    private func required(_ key: String, _ arguments: [String: Value]) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else { throw ToolError("Missing \(key).") }
        return value
    }

    /// Replies as JSON: text stays text (binary escaped), arrays are capped at `maxLimit`.
    static func jsonValue(_ reply: RESPValue) -> Any {
        switch reply {
        case .simple(let text): text
        case .error(let text): ["error": text]
        case .integer(let number): number
        case .bulk(nil), .array(nil): NSNull()
        case .bulk(let data?): RedisCommand.isBinary(data) ? RedisCommand.display(data) : String(decoding: data, as: UTF8.self)
        case .array(let items?):
            items.count > maxLimit
                ? items.prefix(maxLimit).map(jsonValue) + ["… \(items.count - maxLimit) more not shown"]
                : items.map(jsonValue)
        }
    }

    private static func summary(_ reply: RESPValue) -> String {
        switch reply {
        case .array(let items?): "\(items.count) item(s)"
        case .integer(let number): "(integer) \(number)"
        case .bulk(nil), .array(nil): "(nil)"
        case .bulk(let data?): "\(data.count) byte(s)"
        case .simple(let text): text
        case .error(let text): text
        }
    }

    /// What the activity log shows in its SQL column: the command, as redis-cli would take it.
    static func loggedCommand(_ tool: String, _ arguments: [String: Value]) -> String? {
        switch tool {
        case "scan_keys":
            let type = arguments["type"]?.stringValue.map { " TYPE \($0)" } ?? ""
            return "SCAN MATCH \(arguments["pattern"]?.stringValue ?? "*")\(type)"
        case "get_key":
            return arguments["key"]?.stringValue.map { "-- read key \(RedisCommand.quote(Data($0.utf8)))" }
        case "run_command", "execute_command":
            if let args = arguments["args"]?.arrayValue?.compactMap(\.stringValue) {
                return args.map { RedisCommand.quote(Data($0.utf8)) }.joined(separator: " ")
            }
            return arguments["command"]?.stringValue
        default:
            return nil
        }
    }

    private func json(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
