import Foundation

public enum ConnectionColor: String, Codable, CaseIterable, Sendable {
    case none, red, orange, yellow, green, blue, purple

    /// Red connections are treated as production: writes need an extra confirmation.
    public var isProduction: Bool { self == .red }
}

/// What AI clients connected over MCP may do with a connection.
public enum MCPAccess: String, Codable, CaseIterable, Sendable {
    /// Not listed to AI clients at all.
    case hidden
    /// SELECT / SHOW / DESCRIBE / EXPLAIN only.
    case readOnly
    /// Also INSERT / UPDATE / DELETE / DDL. Production (red) connections still ask first.
    case readWrite
}

public enum SSLMode: String, Codable, CaseIterable, Sendable {
    /// Use TLS when the server offers it, otherwise connect in plain text.
    case preferred
    case disabled
    /// Always TLS. Redis can't negotiate it (TLS is on or off per port), so Redis connections use this or `disabled`.
    case required
}

/// What kind of server a saved connection talks to. Connections saved before Redis existed are MySQL.
public enum DatabaseKind: String, Codable, CaseIterable, Sendable {
    case mysql
    case redis

    public var title: String {
        switch self {
        case .mysql: "MySQL"
        case .redis: "Redis"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .mysql: 3306
        case .redis: 6379
        }
    }
}

public struct ConnectionProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: DatabaseKind
    public var name: String
    /// One level of grouping. `nil` or empty means the connection sits on the home screen.
    public var group: String?
    public var host: String
    public var port: Int
    /// For Redis, the ACL user; empty logs in with the password only (the `default` user).
    public var user: String
    public var defaultSchema: String
    /// Redis only: the database number to `SELECT` after logging in.
    public var redisDatabase: Int
    public var color: ConnectionColor
    public var sslMode: SSLMode
    public var rowLimit: Int?
    public var mcpAccess: MCPAccess
    /// A separate MySQL user for AI clients, so MySQL's own grants limit them. Empty = use `user`.
    /// Its password is in the Keychain under `Keychain.Kind.mcp`.
    public var mcpUser: String

    public init(
        id: UUID = UUID(),
        kind: DatabaseKind = .mysql,
        name: String = "",
        group: String? = nil,
        host: String = "localhost",
        port: Int = 3306,
        user: String = "root",
        defaultSchema: String = "",
        redisDatabase: Int = 0,
        color: ConnectionColor = .none,
        sslMode: SSLMode = .preferred,
        rowLimit: Int? = 1000,
        mcpAccess: MCPAccess = .readOnly,
        mcpUser: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.group = group
        self.host = host
        self.port = port
        self.user = user
        self.defaultSchema = defaultSchema
        self.redisDatabase = redisDatabase
        self.color = color
        self.sslMode = sslMode
        self.rowLimit = rowLimit
        self.mcpAccess = mcpAccess
        self.mcpUser = mcpUser
    }

    public var usesSeparateMCPUser: Bool {
        !mcpUser.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The MySQL user AI clients log in as.
    public var effectiveMCPUser: String {
        usesSeparateMCPUser ? mcpUser.trimmingCharacters(in: .whitespaces) : user
    }

    /// Fields added later are optional in the file, so older connections.json files still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ConnectionProfile()
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decodeIfPresent(DatabaseKind.self, forKey: .kind) ?? defaults.kind
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? defaults.name
        group = try container.decodeIfPresent(String.self, forKey: .group)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? defaults.host
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? defaults.port
        user = try container.decodeIfPresent(String.self, forKey: .user) ?? defaults.user
        defaultSchema = try container.decodeIfPresent(String.self, forKey: .defaultSchema) ?? defaults.defaultSchema
        redisDatabase = try container.decodeIfPresent(Int.self, forKey: .redisDatabase) ?? defaults.redisDatabase
        color = try container.decodeIfPresent(ConnectionColor.self, forKey: .color) ?? defaults.color
        sslMode = try container.decodeIfPresent(SSLMode.self, forKey: .sslMode) ?? defaults.sslMode
        rowLimit = try container.decodeIfPresent(Int.self, forKey: .rowLimit)
        mcpAccess = try container.decodeIfPresent(MCPAccess.self, forKey: .mcpAccess) ?? defaults.mcpAccess
        mcpUser = try container.decodeIfPresent(String.self, forKey: .mcpUser) ?? defaults.mcpUser
    }

    public var groupName: String? {
        guard let group = group?.trimmingCharacters(in: .whitespaces), !group.isEmpty else { return nil }
        return group
    }

    public var address: String { "\(host):\(port)" }

    /// A new Redis connection: no user (password-only login), plain TCP like a default Redis install.
    public static func redis(host: String = "localhost", port: Int = 6379) -> ConnectionProfile {
        ConnectionProfile(kind: .redis, host: host, port: port, user: "", sslMode: .disabled)
    }

    /// Switches a connection being edited to another kind, moving the port and user along if they were the old defaults.
    public mutating func change(kind newKind: DatabaseKind) {
        guard newKind != kind else { return }
        if port == kind.defaultPort { port = newKind.defaultPort }
        switch newKind {
        case .redis:
            if user == "root" { user = "" }
            if sslMode == .preferred { sslMode = .disabled }
        case .mysql:
            if user.isEmpty { user = "root" }
            // Preferred also works with servers without TLS, so it's right whatever Redis had.
            sslMode = .preferred
        }
        kind = newKind
    }

    /// Anything but this Mac. The query editor turns red for these, so a remote server is never mistaken for local.
    public var isRemote: Bool { !LocalMySQLServer.isLocal(host: host) }

    /// MySQL's built-in schemas. Every user can see them, but only root needs them listed.
    public static let systemSchemas: Set<String> = ["information_schema", "performance_schema", "mysql", "sys"]

    /// The schemas to list for this connection: everything for root, no system schemas for anyone else.
    public func visibleSchemas(_ names: [String]) -> [String] {
        user == "root" ? names : names.filter { !Self.systemSchemas.contains($0.lowercased()) }
    }
}
