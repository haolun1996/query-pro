import Foundation
import MCP
import SQCore
import Testing
@testable import SQMCP

/// Hands out passwords per Keychain kind, like the app does, without touching the Keychain.
private struct LoginProvider: MCPProvider {
    let saved: [ConnectionProfile]
    let connectionPassword: String?
    let aiPassword: String?

    func profiles() async -> [ConnectionProfile] { saved }
    func password(for profile: ConnectionProfile) async -> String? {
        profile.usesSeparateMCPUser ? aiPassword : connectionPassword
    }
    func approveWrite(_ sql: String, on profile: ConnectionProfile) async -> Bool { false }
    func record(_ activity: MCPActivity) async {}
}

/// Runs against the MySQL on localhost:3306 when it accepts root without a password (the dev setup);
/// otherwise the tests return early, unless SQPRO_REQUIRE_MYSQL is set.
@Suite struct MCPLoginTests {
    /// Set SQPRO_REQUIRE_MYSQL=1 to fail instead of skipping when the database isn't there.
    private static func localRootAvailable() async -> Bool {
        let session = MySQLSession(profile: ConnectionProfile(host: "127.0.0.1", user: "root"), password: "")
        defer { Task { await session.close() } }
        let available = (try? await session.connect()) != nil
        if !available, ProcessInfo.processInfo.environment["SQPRO_REQUIRE_MYSQL"] != nil {
            Issue.record("Local MySQL (root, no password) is not reachable")
        }
        return available
    }

    private func text(_ result: CallTool.Result) -> String {
        guard case .text(let text, _, _) = result.content.first else { return "" }
        return text
    }

    @Test func toolsLogInAsTheSeparateAIUser() async {
        guard await Self.localRootAvailable() else { return }
        // The connection's own user doesn't exist, so this only works if MCP logs in as the AI user.
        let profile = ConnectionProfile(name: "Dev", host: "127.0.0.1", user: "sqpro_no_such_user", mcpUser: "root")
        let tools = SQLTools(provider: LoginProvider(saved: [profile], connectionPassword: "wrong", aiPassword: ""), connection: profile.id)
        let result = await tools.call("list_databases", arguments: [:])
        #expect(result.isError != true, "\(text(result))")
        // Root sees the system schemas, so the AI really is root here.
        #expect(text(result).contains("information_schema"))
        let info = await tools.call("connection_info", arguments: [:])
        #expect(text(info).contains(#""user":"root""#))
    }

    @Test func aWrongAIUserIsRefusedEvenIfTheConnectionUserWorks() async {
        guard await Self.localRootAvailable() else { return }
        let profile = ConnectionProfile(name: "Dev", host: "127.0.0.1", user: "root", mcpUser: "sqpro_no_such_user")
        let tools = SQLTools(provider: LoginProvider(saved: [profile], connectionPassword: "", aiPassword: "x"), connection: profile.id)
        let result = await tools.call("run_query", arguments: ["sql": "select 1"])
        #expect(result.isError == true)
        #expect(text(result).contains("1045"), "\(text(result))")
    }
}
