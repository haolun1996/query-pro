import Foundation
import MCP
import SQCore
import Testing
@testable import SQMCP

private actor RedisProvider: MCPProvider {
    let saved: [ConnectionProfile]
    let passwords: [UUID: String]
    let approves: Bool
    private(set) var activity: [MCPActivity] = []
    private(set) var approvalRequests: [String] = []

    init(_ saved: [ConnectionProfile], passwords: [UUID: String] = [:], approves: Bool = false) {
        self.saved = saved
        self.passwords = passwords
        self.approves = approves
    }

    func profiles() async -> [ConnectionProfile] { saved }
    func password(for profile: ConnectionProfile) async -> String? { passwords[profile.id] }
    func approveWrite(_ sql: String, on profile: ConnectionProfile) async -> Bool {
        approvalRequests.append(sql)
        return approves
    }
    func record(_ activity: MCPActivity) async { self.activity.append(activity) }
}

private func text(_ result: CallTool.Result) -> String {
    guard case .text(let text, _, _) = result.content.first else { return "" }
    return text
}

private func redis(_ name: String, port: Int, access: MCPAccess, color: ConnectionColor = .none) -> ConnectionProfile {
    var profile = ConnectionProfile.redis(host: "127.0.0.1", port: port)
    profile.name = name
    profile.mcpAccess = access
    profile.color = color
    return profile
}

@Suite struct RedisToolsTests {
    // Port 1 refuses connections: anything that gets as far as connecting fails fast.
    let reader = redis("Cache", port: 1, access: .readOnly)
    let live = redis("LIVE cache", port: 1, access: .readWrite, color: .red)

    @Test func connectionInfo() async {
        let result = await RedisTools(provider: RedisProvider([reader]), connection: reader.id).call("connection_info", arguments: [:])
        #expect(result.isError == false)
        #expect(text(result).contains(#""kind":"redis""#))
        #expect(text(result).contains(#""user":"default""#))
    }

    /// Refused before any connection is opened.
    @Test func refusesWithoutConnecting() async {
        let provider = RedisProvider([reader, live], approves: true)
        let tools = RedisTools(provider: provider, connection: reader.id)
        for (tool, command) in [("run_command", "SET k v"), ("run_command", "KEYS *"), ("run_command", "FLUSHALL"),
                                ("execute_command", "SET k v"), ("run_command", "EVAL \"return 1\" 0"), ("run_command", "BLPOP q 0")] {
            let result = await tools.call(tool, arguments: ["command": .string(command)])
            #expect(result.isError == true, "\(tool) \(command)")
            #expect(!text(result).contains("Can't connect"), "\(tool) \(command) reached the server: \(text(result))")
        }
        // Even with read_write, administration never runs.
        let writer = RedisTools(provider: provider, connection: live.id)
        let flush = await writer.call("execute_command", arguments: ["args": ["FLUSHDB"]])
        #expect(flush.isError == true && text(flush).contains("administration"))
        #expect(await provider.approvalRequests.isEmpty)
        let blocked = await provider.activity.filter { if case .blocked = $0.outcome { true } else { false } }
        #expect(blocked.count == 7)
    }

    @Test func productionWritesAsk() async {
        let provider = RedisProvider([live], approves: false)
        let result = await RedisTools(provider: provider, connection: live.id).call("execute_command", arguments: ["args": ["SET", "a b", "1"]])
        #expect(result.isError == true && text(result).contains("declined"))
        #expect(await provider.approvalRequests == [#""SET" "a b" "1""#])
    }

    @Test func badSyntaxIsReported() async {
        let result = await RedisTools(provider: RedisProvider([reader]), connection: reader.id)
            .call("run_command", arguments: ["command": .string(#"GET "unclosed"#)])
        #expect(result.isError == true && text(result).contains("unbalanced quotes"))
    }

    @Test func repliesAsJSON() {
        let reply = RESPValue.array([.bulk(Data("a".utf8)), .integer(2), .bulk(nil), .bulk(Data([0xFF]))])
        let value = RedisTools.jsonValue(reply) as? [Any]
        #expect(value?.count == 4)
        #expect(value?[0] as? String == "a")
        #expect(value?[3] as? String == #"\xff"#)
    }
}

/// Against a real server, like `RedisLiveTests`: `SQPRO_REDIS=127.0.0.1:6390 SQPRO_REDIS_PASSWORD=…`, and for the
/// AI-user test `SQPRO_REDIS_ACL_USER` / `SQPRO_REDIS_ACL_PASSWORD` (a user limited to reads).
@Suite(.serialized) struct RedisToolsLiveTests {
    static let environment = ProcessInfo.processInfo.environment
    static var isConfigured: Bool { environment["SQPRO_REDIS"] != nil }
    static var port: Int { Int(environment["SQPRO_REDIS"]?.split(separator: ":").last ?? "") ?? 6379 }

    @Test(.enabled(if: isConfigured)) func readsAndWrites() async throws {
        let profile = redis("Scratch", port: Self.port, access: .readWrite)
        let provider = RedisProvider([profile], passwords: [profile.id: Self.environment["SQPRO_REDIS_PASSWORD"] ?? ""])
        let tools = RedisTools(provider: provider, connection: profile.id)

        let set = await tools.call("execute_command", arguments: ["args": ["HSET", "qp:mcp:h", "name", "Ada", "visits", "3"]])
        #expect(set.isError == false, "\(text(set))")
        let scan = await tools.call("scan_keys", arguments: ["pattern": "qp:mcp:*"])
        #expect(text(scan).contains(#""key":"qp:mcp:h""#) && text(scan).contains(#""type":"hash""#))
        let get = await tools.call("get_key", arguments: ["key": "qp:mcp:h"])
        #expect(text(get).contains(#""name":"Ada""#) && text(get).contains(#""total":2"#))
        let read = await tools.call("run_command", arguments: ["command": "HGET qp:mcp:h visits"])
        #expect(text(read) == #"{"reply":"3"}"#)
        let info = await tools.call("server_info", arguments: [:])
        #expect(text(info).contains("redis_version"))
        let missing = await tools.call("get_key", arguments: ["key": "qp:mcp:none"])
        #expect(missing.isError == true)
        // A Redis error reply is a failed call, not a crash.
        let wrongType = await tools.call("run_command", arguments: ["command": "LRANGE qp:mcp:h 0 -1"])
        #expect(wrongType.isError == true && text(wrongType).hasPrefix("WRONGTYPE"))
        _ = await tools.call("execute_command", arguments: ["args": ["DEL", "qp:mcp:h"]])
    }

    /// With a separate AI user, the server's ACL refuses writes even when Query Pro would allow them.
    @Test(.enabled(if: isConfigured && environment["SQPRO_REDIS_ACL_USER"] != nil)) func aiUserLimitsWrites() async throws {
        var profile = redis("Scratch", port: Self.port, access: .readWrite)
        profile.mcpUser = Self.environment["SQPRO_REDIS_ACL_USER"] ?? ""
        let provider = RedisProvider([profile], passwords: [profile.id: Self.environment["SQPRO_REDIS_ACL_PASSWORD"] ?? ""])
        let tools = RedisTools(provider: provider, connection: profile.id)
        let scan = await tools.call("scan_keys", arguments: [:])
        #expect(scan.isError == false, "\(text(scan))")
        let write = await tools.call("execute_command", arguments: ["command": "SET qp:mcp:acl x"])
        #expect(write.isError == true && text(write).hasPrefix("NOPERM"))
    }
}
