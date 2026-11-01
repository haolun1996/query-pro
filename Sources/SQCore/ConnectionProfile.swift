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
}

public struct ConnectionProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// One level of grouping. `nil` or empty means the connection sits on the home screen.
    public var group: String?
    public var host: String
    public var port: Int
    public var user: String
    public var defaultSchema: String
    public var color: ConnectionColor
    public var sslMode: SSLMode
    public var rowLimit: Int?
    public var mcpAccess: MCPAccess
    /// A separate MySQL user for AI clients, so MySQL's own grants limit them. Empty = use `user`.
    /// Its password is in the Keychain under `Keychain.Kind.mcp`.
    public var mcpUser: String

    public init(
        id: UUID = UUID(),
        name: String = "",
        group: String? = nil,
        host: String = "localhost",
        port: Int = 3306,
        user: String = "root",
        defaultSchema: String = "",
        color: ConnectionColor = .none,
        sslMode: SSLMode = .preferred,
        rowLimit: Int? = 1000,
        mcpAccess: MCPAccess = .readOnly,
        mcpUser: String = ""
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.host = host
        self.port = port
        self.user = user
        self.defaultSchema = defaultSchema
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
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? defaults.name
        group = try container.decodeIfPresent(String.self, forKey: .group)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? defaults.host
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? defaults.port
        user = try container.decodeIfPresent(String.self, forKey: .user) ?? defaults.user
        defaultSchema = try container.decodeIfPresent(String.self, forKey: .defaultSchema) ?? defaults.defaultSchema
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

    /// MySQL's built-in schemas. Every user can see them, but only root needs them listed.
    public static let systemSchemas: Set<String> = ["information_schema", "performance_schema", "mysql", "sys"]

    /// The schemas to list for this connection: everything for root, no system schemas for anyone else.
    public func visibleSchemas(_ names: [String]) -> [String] {
        user == "root" ? names : names.filter { !Self.systemSchemas.contains($0.lowercased()) }
    }
}
