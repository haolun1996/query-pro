import Foundation
import MySQLNIO
import NIOPosix
import NIOSSL

public enum SessionError: Error, LocalizedError {
    case notConnected
    /// The connection dropped while a statement was running. Querywell reconnected, but can't know whether it ran.
    case lostDuringStatement
    /// The connection dropped inside a transaction; the server rolled the transaction back.
    case lostTransaction

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            "Not connected to the server."
        case .lostDuringStatement:
            "The connection to the server was lost while this statement was running. Querywell has reconnected; check whether the statement took effect before running it again."
        case .lostTransaction:
            "The connection to the server was lost during an open transaction, so the server rolled it back. Querywell has reconnected; nothing since START TRANSACTION was saved."
        }
    }
}

/// One live connection to a MySQL server. Statements run one at a time, in order.
///
/// Reconnects by itself when the server has dropped the connection (idle timeout, sleep, network change):
/// after a quiet spell it checks the connection before using it, and a read-only statement that fails on a
/// dropped connection is retried once. Anything else is never re-run blindly.
public actor MySQLSession {
    public let profile: ConnectionProfile
    private var connection: MySQLConnection?
    /// Server-side id of this connection, used to cancel a running query with `KILL QUERY`.
    public private(set) var connectionID: UInt64?
    private let password: String?

    /// Used again on reconnect, so `USE` survives a dropped connection.
    private var database: String
    /// From the last OK packet: the server reported an open transaction.
    private var inTransaction = false
    private var lastUsed = ContinuousClock.now
    private var reconnected = false
    /// After this long without a statement, check the connection is still alive before using it.
    private static let idleCheck = Duration.seconds(30)

    public init(profile: ConnectionProfile, password: String?) {
        self.profile = profile
        self.password = password
        self.database = profile.defaultSchema
    }

    public func connect() async throws {
        if let connection, !connection.isClosed { return }
        try await open()
    }

    public func close() async {
        try? await connection?.close().get()
        connection = nil
    }

    /// The schema to return to after a reconnect.
    public func remember(database: String?) {
        self.database = database ?? ""
    }

    /// `true` once after the session had to reconnect, so the app can say so.
    public func takeReconnectNotice() -> Bool {
        defer { reconnected = false }
        return reconnected
    }

    public func execute(_ sql: String) async throws -> QueryResult {
        guard connection != nil else { throw SessionError.notConnected }
        try await reviveIfNeeded()
        do {
            return try await run(sql)
        } catch where Self.isConnectionLost(error) {
            let hadTransaction = inTransaction
            try await reconnect()
            if hadTransaction { throw SessionError.lostTransaction }
            guard SQL.isReadOnly(sql) else { throw SessionError.lostDuringStatement }
            return try await run(sql)
        }
    }

    // MARK: Connection health

    private func open() async throws {
        connection = try await Self.open(profile: profile, password: password, database: database)
        inTransaction = false
        lastUsed = .now
        connectionID = try await run("SELECT CONNECTION_ID()").rows.first?.first.flatMap { $0.flatMap(UInt64.init) }
    }

    private func reconnect() async throws {
        if let connection { _ = connection.close() }
        connection = nil
        do {
            try await open()
        } catch where !database.isEmpty {
            // The schema may have been dropped meanwhile; connect without it.
            database = ""
            try await open()
        }
        reconnected = true
    }

    /// Reconnects when the connection is closed, or after a quiet spell doesn't answer a ping within 5 seconds.
    /// A connection left open in a transaction is reported instead of silently replaced.
    private func reviveIfNeeded() async throws {
        guard let connection else { return }
        var alive = !connection.isClosed
        if alive, ContinuousClock.now - lastUsed > Self.idleCheck {
            alive = await Self.ping(connection)
        }
        guard !alive else { return }
        let hadTransaction = inTransaction
        try await reconnect()
        if hadTransaction { throw SessionError.lostTransaction }
    }

    private static func ping(_ connection: MySQLConnection) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await connection.simpleQuery("SELECT 1").get()) != nil }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                // Closing fails the stuck ping, so the group can finish.
                connection.channel.close(promise: nil)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// Errors meaning the connection is gone, as opposed to the statement failing.
    static func isConnectionLost(_ error: any Error) -> Bool {
        switch error {
        case MySQLError.closed, is ChannelError, is IOError, SessionError.notConnected:
            return true
        case MySQLError.server(let packet):
            // 4031: disconnected for inactivity (MySQL 8.0.24+). 2006 / 2013: server gone away / lost connection.
            return [4031, 2006, 2013].contains(packet.errorCode.rawValue)
        case let error as NIOSSLError:
            if case .uncleanShutdown = error { return true }
            return false
        default:
            return false
        }
    }

    private func run(_ sql: String) async throws -> QueryResult {
        guard let connection, !connection.isClosed else { throw SessionError.notConnected }
        let command = TextQueryCommand(sql: sql)
        let clock = ContinuousClock()
        let start = clock.now
        defer { lastUsed = .now }
        try await connection.send(command, logger: connection.logger).get()
        let duration = clock.now - start
        if let ok = command.ok {
            inTransaction = ok.statusFlags.contains(.SERVER_STATUS_IN_TRANS)
            if let schema = SQL.useTarget(sql) { database = schema }
        }

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
