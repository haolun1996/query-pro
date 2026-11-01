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

    /// Kills the session's connection from a second one and waits until the client notices.
    private func drop(_ session: MySQLSession) async throws {
        let killer = MySQLSession(profile: profile, password: "")
        try await killer.connect()
        let id = try #require(await session.connectionID)
        _ = try await killer.execute("KILL \(id)")
        await killer.close()
        try await Task.sleep(for: .milliseconds(200))
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
