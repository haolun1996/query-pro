import Foundation
import Testing
@testable import SQCore

/// Drops the connection from the server side with KILL, the way an idle timeout or sleep would.
/// Runs against the MySQL on localhost:3306 when it accepts root without a password; otherwise returns early,
/// unless SQPRO_REQUIRE_MYSQL is set.
@Suite(.serialized) struct ReconnectTests {
    private let profile = ConnectionProfile(host: "127.0.0.1", user: "root")

    private func connectedSession() async -> MySQLSession? {
        let session = MySQLSession(profile: profile, password: "")
        do {
            try await session.connect()
            return session
        } catch {
            if ProcessInfo.processInfo.environment["SQPRO_REQUIRE_MYSQL"] != nil {
                Issue.record("Local MySQL (root, no password) is not reachable")
            }
            return nil
        }
    }

    /// Kills the session's connection from a second one and, unless told not to, waits until the client notices.
    private func drop(_ session: MySQLSession, waitForClose: Bool = true) async throws {
        let killer = MySQLSession(profile: profile, password: "")
        try await killer.connect()
        let id = try #require(await session.connectionID)
        _ = try await killer.execute("KILL \(id)")
        await killer.close()
        if waitForClose { try await Task.sleep(for: .milliseconds(200)) }
    }

    @Test func reconnectsAndKeepsTheSchema() async throws {
        guard let session = await connectedSession() else { return }
        _ = try await session.execute("USE mysql")
        await session.remember(database: "mysql")
        let before = await session.connectionID
        try await drop(session)

        let result = try await session.execute("SELECT DATABASE()")
        #expect(result.rows.first?.first == "mysql")
        #expect(await session.connectionID != before)
        #expect(await session.takeReconnectNotice())
        #expect(await session.takeReconnectNotice() == false)
        await session.close()
    }

    @Test func useIsRememberedForReconnects() async throws {
        #expect(SQL.useTarget("use pos;") == "pos")
        #expect(SQL.useTarget("USE `my``db`") == "my`db")
        #expect(SQL.useTarget("select 1") == nil)
        guard let session = await connectedSession() else { return }
        _ = try await session.execute("USE mysql")
        try await drop(session)
        #expect(try await session.execute("SELECT DATABASE()").rows.first?.first == "mysql")
        await session.close()
    }

    /// The idle check's timer used to close the connection even after the ping answered, so every statement after a
    /// quiet spell hit a dead connection, and USE failed with "lost while running".
    @Test func anIdleLiveConnectionIsKept() async throws {
        let session = MySQLSession(profile: profile, password: "", idleCheck: .milliseconds(100))
        do { try await session.connect() } catch { return }
        let before = await session.connectionID
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(300))
            _ = try await session.execute("USE mysql")
        }
        #expect(await session.connectionID == before)
        #expect(await session.takeReconnectNotice() == false)
        await session.close()
    }

    @Test func useIsRetriedAfterADrop() async throws {
        guard let session = await connectedSession() else { return }
        try await drop(session, waitForClose: false)
        // The client hasn't seen the drop yet, so USE fails on the dead connection and is run again on a new one.
        _ = try await session.execute("USE mysql")
        #expect(try await session.execute("SELECT DATABASE()").rows.first?.first == "mysql")
        await session.close()
    }

    /// A server that accepts the TCP connection but never sends its greeting (seen after sleep) must not hang connect.
    @Test func aSilentServerTimesOut() async throws {
        let listener = try SilentListener()
        defer { listener.close() }
        let silent = ConnectionProfile(host: "127.0.0.1", port: listener.port, user: "root")
        let session = MySQLSession(profile: silent, password: "", connectTimeout: .milliseconds(500))
        let start = ContinuousClock.now
        await #expect(throws: SessionError.connectTimedOut) { try await session.connect() }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func aDroppedTransactionIsReportedNotReplaced() async throws {
        guard let session = await connectedSession() else { return }
        _ = try await session.execute("START TRANSACTION")
        try await drop(session)

        await #expect(throws: SessionError.self) { try await session.execute("COMMIT") }
        // The next statement runs normally on the new connection.
        #expect(try await session.execute("SELECT 1").rows.first?.first == "1")
        await session.close()
    }
}

/// Accepts TCP connections (the kernel does, from the listen backlog) and never says anything.
private final class SilentListener {
    private let socket: Int32
    let port: Int

    init() throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                bind(socket, address, length) == 0 && listen(socket, 4) == 0 && getsockname(socket, address, &length) == 0
            }
        }
        guard bound else { Darwin.close(socket); throw POSIXError(.EADDRNOTAVAIL) }
        self.socket = socket
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    func close() { Darwin.close(socket) }
}
