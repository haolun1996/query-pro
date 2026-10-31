import Foundation

public enum ConnectionColor: String, Codable, CaseIterable, Sendable {
    case none, red, orange, yellow, green, blue, purple

    /// Red connections are treated as production: writes need an extra confirmation.
    public var isProduction: Bool { self == .red }
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
        rowLimit: Int? = 1000
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
    }

    public var groupName: String? {
        guard let group = group?.trimmingCharacters(in: .whitespaces), !group.isEmpty else { return nil }
        return group
    }

    public var address: String { "\(host):\(port)" }
}
