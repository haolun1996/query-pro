import Foundation
import MySQLNIO
import NIOPosix
import NIOSSL

public enum SessionError: Error, LocalizedError {
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to the server."
        }
    }
}

/// One live connection to a MySQL server. Statements run one at a time, in order.
public actor MySQLSession {
    public let profile: ConnectionProfile
    private var connection: MySQLConnection?
    /// Server-side id of this connection, used to cancel a running query with `KILL QUERY`.
    public private(set) var connectionID: UInt64?
    private let password: String?

    public init(profile: ConnectionProfile, password: String?) {
        self.profile = profile
        self.password = password
    }

    public func connect() async throws {
        if let connection, !connection.isClosed { return }
        connection = try await Self.open(profile: profile, password: password, database: profile.defaultSchema)
        connectionID = try await execute("SELECT CONNECTION_ID()").rows.first?.first.flatMap { $0.flatMap(UInt64.init) }
    }

    public func close() async {
        try? await connection?.close().get()
        connection = nil
    }

    public func execute(_ sql: String) async throws -> QueryResult {
        guard let connection, !connection.isClosed else { throw SessionError.notConnected }
        let command = TextQueryCommand(sql: sql)
        let clock = ContinuousClock()
        let start = clock.now
        try await connection.send(command, logger: connection.logger).get()
        let duration = clock.now - start

        let columns = command.columns.map { definition in
            ColumnInfo(
                name: definition.name,
                schema: definition.schema,
                table: definition.orgTable,
                originalName: definition.orgName,
                typeName: Self.typeName(definition.columnType),
                isPrimaryKey: definition.flags.contains(.PRIMARY_KEY),
                isNotNull: definition.flags.contains(.COLUMN_NOT_NULL),
                isBinary: Self.isBinary(definition),
                // AUTO_INCREMENT_FLAG (0x200); mysql-nio has no named constant for it.
                isAutoIncrement: definition.flags.rawValue & 0x200 != 0
            )
        }
        let rows = command.rows.map { values in
            zip(values, columns).map { value, column in value.map { Self.text(from: $0, binary: column.isBinary) } }
        }
        return QueryResult(
            sql: sql,
            columns: columns,
            rows: rows,
            hasResultSet: command.ok == nil,
            affectedRows: command.ok?.affectedRows ?? 0,
            lastInsertID: command.ok?.lastInsertID,
            info: command.ok?.info ?? "",
            duration: duration
        )
    }

    /// Stops the statement currently running on this session, using a second short-lived connection.
    public func cancelRunningQuery() async throws {
        guard let connectionID else { return }
        let killer = try await Self.open(profile: profile, password: password, database: "")
        defer { _ = killer.close() }
        _ = try await killer.simpleQuery("KILL QUERY \(connectionID)").get()
    }

    private static func open(profile: ConnectionProfile, password: String?, database: String) async throws -> MySQLConnection {
        let eventLoop = MultiThreadedEventLoopGroup.singleton.next()
        let address = try SocketAddress.makeAddressResolvingHost(profile.host, port: profile.port)
        var tls: TLSConfiguration?
        if profile.sslMode == .preferred {
            // Same behaviour as Workbench's "use SSL if available": encrypt, but accept self-signed server certificates.
            var configuration = TLSConfiguration.makeClientConfiguration()
            configuration.certificateVerification = .none
            tls = configuration
        }
        return try await MySQLConnection.connect(
            to: address,
            username: profile.user,
            database: database,
            password: password,
            tlsConfiguration: tls,
            on: eventLoop
        ).get()
    }

    /// Numbers and dates also use the `binary` character set, so only string-like types count as binary data.
    private static func isBinary(_ definition: MySQLProtocol.ColumnDefinition41) -> Bool {
        let stringTypes: [MySQLProtocol.DataType] = [.varchar, .varString, .string, .tinyBlob, .mediumBlob, .longBlob, .blob, .bit, .geometry]
        return definition.characterSet == .binary && stringTypes.contains(definition.columnType)
    }

    private static func typeName(_ type: MySQLProtocol.DataType) -> String {
        type.name.replacingOccurrences(of: "MYSQL_TYPE_", with: "")
    }

    private static func text(from buffer: ByteBuffer, binary: Bool) -> String {
        let bytes = buffer.readableBytesView
        if !binary, let string = String(bytes: bytes, encoding: .utf8) { return string }
        return "0x" + bytes.map { String(format: "%02X", $0) }.joined()
    }
}
