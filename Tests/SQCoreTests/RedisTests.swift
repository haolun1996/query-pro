import Foundation
import NIOCore
import Testing
@testable import SQCore

@Suite struct RESPTests {
    private func parse(_ text: String) throws -> RESPValue? {
        var buffer = ByteBuffer(string: text)
        return try RESP.parse(&buffer)
    }

    @Test func scalars() throws {
        #expect(try parse("+OK\r\n") == .simple("OK"))
        #expect(try parse("-ERR unknown\r\n") == .error("ERR unknown"))
        #expect(try parse(":-42\r\n") == .integer(-42))
        #expect(try parse("$5\r\nhe\r\no\r\n") == .bulk(Data("he\r\no".utf8)))
        #expect(try parse("$0\r\n\r\n") == .bulk(Data()))
        #expect(try parse("$-1\r\n") == .bulk(nil))
        #expect(try parse("*-1\r\n") == .array(nil))
    }

    @Test func nestedArrays() throws {
        let value = try parse("*2\r\n$1\r\na\r\n*2\r\n:1\r\n+x\r\n")
        #expect(value == .array([.bulk(Data("a".utf8)), .array([.integer(1), .simple("x")])]))
    }

    /// Replies arrive in pieces; nothing is consumed until a whole one is there.
    @Test func incompleteLeavesTheBuffer() throws {
        for partial in ["", "+O", "$5\r\nhel", "*2\r\n:1\r\n", "$3\r\nabc\r"] {
            var buffer = ByteBuffer(string: partial)
            #expect(try RESP.parse(&buffer) == nil)
            #expect(buffer.readableBytes == partial.utf8.count)
        }
    }

    @Test func twoRepliesInOneBuffer() throws {
        var buffer = ByteBuffer(string: "+OK\r\n:7\r\n")
        #expect(try RESP.parse(&buffer) == .simple("OK"))
        #expect(try RESP.parse(&buffer) == .integer(7))
        #expect(buffer.readableBytes == 0)
    }

    @Test func garbageThrows() {
        #expect(throws: RESP.ProtocolError.self) { try parse("HTTP/1.1 400\r\n") }
    }

    @Test func encodesCommands() {
        var buffer = ByteBuffer()
        RESP.encode([Data("SET".utf8), Data("k".utf8), Data([0, 0xFF])], into: &buffer)
        #expect(buffer.readBytes(length: buffer.readableBytes) == Array("*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$2\r\n".utf8) + [0, 0xFF, 13, 10])
    }
}

@Suite struct RedisCommandTests {
    private func words(_ line: String) throws -> [String] {
        try RedisCommand.parse(line).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func splitsLikeRedisCli() throws {
        #expect(try words("  set  key value ") == ["set", "key", "value"])
        #expect(try words(#"set "a b" 'c d'"#) == ["set", "a b", "c d"])
        #expect(try words(#"set k "line\nbreak \"q\"""#) == ["set", "k", "line\nbreak \"q\""])
        #expect(try words(#"set k 'it\'s'"#) == ["set", "k", "it's"])
        #expect(try words(#"set k """#) == ["set", "k", ""])
        #expect(try words("") == [])
        #expect(try RedisCommand.parse(#"set k "\x00\xff""#)[2] == Data([0, 0xFF]))
    }

    @Test func badQuotesThrow() {
        for line in [#"set "open"#, #"set 'open"#, #"set "a"b"#] {
            #expect(throws: RedisCommand.SyntaxError.self) { try RedisCommand.parse(line) }
        }
    }

    @Test func formatsLikeRedisCli() {
        #expect(RedisCommand.format(.simple("OK")) == "OK")
        #expect(RedisCommand.format(.integer(3)) == "(integer) 3")
        #expect(RedisCommand.format(.bulk(nil)) == "(nil)")
        #expect(RedisCommand.format(.error("ERR x")) == "(error) ERR x")
        #expect(RedisCommand.format(.array([])) == "(empty array)")
        #expect(RedisCommand.format(.bulk(Data("say \"hi\"\n".utf8))) == #""say \"hi\"\n""#)
        #expect(RedisCommand.format(.bulk(Data([0x41, 0x00, 0xFF]))) == #""A\x00\xff""#)
        let nested = RESPValue.array([.bulk(Data("0".utf8)), .array([.bulk(Data("a".utf8)), .bulk(Data("b".utf8))])])
        #expect(RedisCommand.format(nested) == """
            1) "0"
            2) 1) "a"
               2) "b"
            """)
        let ten = RESPValue.array((1...10).map { .integer(Int64($0)) })
        #expect(RedisCommand.format(ten).split(separator: "\n").first == " 1) (integer) 1")
    }

    @Test func displayKeepsTextAndEscapesBinary() {
        #expect(RedisCommand.display(Data("café:1".utf8)) == "café:1")
        #expect(RedisCommand.display(Data([0x00, 0x41])) == #"\x00A"#)
        #expect(!RedisCommand.isBinary(Data("two\nlines".utf8)))
        #expect(RedisCommand.isBinary(Data([0xFF, 0xFE])))
    }

    @Test func accessForAI() {
        #expect(RedisCommand.access(["get", "k"]) == .read)
        #expect(RedisCommand.access(["HGETALL", "k"]) == .read)
        #expect(RedisCommand.access(["object", "encoding", "k"]) == .read)
        #expect(RedisCommand.access(["XREAD", "COUNT", "5", "STREAMS", "s", "0"]) == .read)
        #expect(RedisCommand.access(["SET", "k", "v"]) == .write)
        #expect(RedisCommand.access(["OBJECT", "FREQUENCY", "k"]) == .write)
        #expect(RedisCommand.access(["SOMEMODULE.CMD"]) == .write)
        #expect(RedisCommand.access(["XREADGROUP", "GROUP", "g", "c", "STREAMS", "s", ">"]) == .write)
        for refused in [["KEYS", "*"], ["flushall"], ["CONFIG", "GET", "*"], ["EVAL", "return 1", "0"], ["BLPOP", "q", "0"],
                        ["XREAD", "BLOCK", "0", "STREAMS", "s", "$"], ["CLIENT", "KILL", "ID", "1"], ["SELECT", "1"], ["MULTI"], []] {
            guard case .refused = RedisCommand.access(refused) else {
                Issue.record("\(refused) should be refused")
                continue
            }
        }
    }

    @Test func productionConfirmations() {
        #expect(RedisCommand.needsConfirmation(["flushdb"]))
        #expect(RedisCommand.needsConfirmation(["CONFIG", "SET", "maxmemory", "1"]))
        #expect(!RedisCommand.needsConfirmation(["CONFIG", "GET", "maxmemory"]))
        #expect(!RedisCommand.needsConfirmation(["DEL", "k"]))
    }
}

@Suite struct RedisBrowserTests {
    private func key(_ name: String) -> RedisKey { RedisKey(name: Data(name.utf8), type: "string", ttl: nil) }

    @Test func groupsKeysIntoFolders() {
        let tree = RedisKeyNode.tree(["user:2:name", "greeting", "user:1:name", "user:1", "a::b"].map(key))
        #expect(tree.map(\.name) == ["user", "a::b", "greeting"])
        let user = tree[0]
        #expect(user.keyCount == 3)
        #expect(user.children?.map(\.name) == ["1", "2", "1"])
        #expect(user.children?.map(\.id) == ["f:user:1", "f:user:2", "k:user:1"])
        #expect(user.children?[0].children?.first?.key?.displayName == "user:1:name")
    }

    @Test func readsKeyspaceAndInfo() {
        let info = "# Keyspace\r\ndb0:keys=11,expires=1,avg_ttl=0\r\ndb2:keys=1,expires=0,avg_ttl=0\r\n"
        #expect(RedisBrowser.keyspace(info) == [0: 11, 2: 1])
        #expect(RedisBrowser.infoField("redis_version", in: "# Server\r\nredis_version:8.12.0\r\n") == "8.12.0")
    }

    @Test func formatsTTL() {
        #expect(RedisBrowser.formatTTL(milliseconds: 500) == "500ms")
        #expect(RedisBrowser.formatTTL(milliseconds: 42_000) == "42s")
        #expect(RedisBrowser.formatTTL(milliseconds: 3_600_000) == "1h")
        #expect(RedisBrowser.formatTTL(milliseconds: 90_061_000) == "1d 1h")
    }

    @Test func profileKindSwitch() throws {
        var profile = ConnectionProfile()
        profile.change(kind: .redis)
        #expect(profile.port == 6379 && profile.user == "" && profile.sslMode == .disabled)
        profile.change(kind: .mysql)
        #expect(profile.port == 3306 && profile.user == "root" && profile.sslMode == .preferred)
        // Saved before Redis existed: no kind in the file.
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"x","host":"h","port":3306,"user":"u"}"#
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: Data(old.utf8))
        #expect(decoded.kind == .mysql && decoded.redisDatabase == 0)
    }
}

/// Against a real server: `SQPRO_REDIS=127.0.0.1:6390 SQPRO_REDIS_PASSWORD=… swift test`. Skipped otherwise.
/// `SQPRO_REDIS_TLS_PORT` also checks TLS. Only writes keys under `qp:test:`.
@Suite(.serialized) struct RedisLiveTests {
    static let environment = ProcessInfo.processInfo.environment
    static let address = environment["SQPRO_REDIS"]?.split(separator: ":")
    static var isConfigured: Bool { address != nil }

    private func profile(port: Int? = nil, tls: Bool = false, user: String = "") -> ConnectionProfile {
        let address = Self.address ?? []
        var profile = ConnectionProfile.redis(host: String(address.first ?? "127.0.0.1"), port: port ?? Int(address.last ?? "6379") ?? 6379)
        profile.user = user
        profile.sslMode = tls ? .required : .disabled
        return profile
    }

    private var password: String? { Self.environment["SQPRO_REDIS_PASSWORD"] }

    @Test(.enabled(if: isConfigured)) func roundTripsEveryType() async throws {
        let session = RedisSession(profile: profile(), password: password)
        try await session.connect()
        defer { Task { await session.close() } }
        let commands: [[String]] = [
            ["DEL", "qp:test:s", "qp:test:h", "qp:test:l", "qp:test:set", "qp:test:z", "qp:test:x"],
            ["SET", "qp:test:s", "hello", "EX", "100"],
            ["HSET", "qp:test:h", "f1", "v1", "f2", "v2"],
            ["RPUSH", "qp:test:l", "a", "b", "c"],
            ["SADD", "qp:test:set", "m1", "m2"],
            ["ZADD", "qp:test:z", "1.5", "one", "2", "two"],
            ["XADD", "qp:test:x", "1-1", "k", "v"],
        ]
        let replies = try await session.sendAll(commands.map { $0.map { Data($0.utf8) } })
        #expect(!replies.contains { $0.isError })

        var cursor = "0"
        var names: Set<Data> = []
        repeat {
            let step = try await RedisBrowser.scan(session, cursor: cursor, pattern: "qp:test:*")
            names.formUnion(step.keys)
            cursor = step.cursor
        } while cursor != "0"
        let keys = try await RedisBrowser.describe(session, Array(names))
        #expect(Set(keys.map(\.type)) == ["string", "hash", "list", "set", "zset", "stream"])
        #expect(keys.first { $0.type == "string" }?.ttl.map { $0 > 90_000 } == true)

        func load(_ name: String, _ type: String, limit: Int = 1000) async throws -> RedisLoadedValue {
            try await RedisBrowser.load(session, key: Data(name.utf8), type: type, limit: limit)
        }
        #expect(try await load("qp:test:s", "string").value == .string(Data("hello".utf8)))
        #expect(try await load("qp:test:l", "list").value == .list(["a", "b", "c"].map { Data($0.utf8) }))
        let firstTwo = try await load("qp:test:l", "list", limit: 2)
        #expect(firstTwo.value.count == 2 && firstTwo.total == 3 && firstTwo.isTruncated)
        #expect(try await load("qp:test:set", "set").value == .set(["m1", "m2"].map { Data($0.utf8) }))
        guard case .hash(let fields) = try await load("qp:test:h", "hash").value else { throw RedisError.notConnected }
        #expect(Set(fields.map { String(decoding: $0.field, as: UTF8.self) }) == ["f1", "f2"])
        guard case .zset(let members) = try await load("qp:test:z", "zset").value else { throw RedisError.notConnected }
        #expect(members.map(\.score) == ["1.5", "2"])
        guard case .stream(let entries) = try await load("qp:test:x", "stream").value else { throw RedisError.notConnected }
        #expect(entries.first?.id == "1-1")

        // Error replies come back as values from send, and throw from call.
        #expect(try await session.send("HGET", "qp:test:s", "f").isError)
        await #expect(throws: RedisError.self) { try await session.call("HGET", "qp:test:s", "f") }
        _ = try await session.send("DEL", "qp:test:s", "qp:test:h", "qp:test:l", "qp:test:set", "qp:test:z", "qp:test:x")
    }

    @Test(.enabled(if: isConfigured)) func wrongPasswordIsAccessDenied() async throws {
        let session = RedisSession(profile: profile(), password: "not-the-password")
        do {
            try await session.connect()
            await session.close()
            Issue.record("A wrong password logged in")
        } catch let error as RedisError {
            #expect(error.isAccessDenied)
        }
    }

    @Test(.enabled(if: isConfigured)) func selectsTheDatabaseAgainAfterAReconnect() async throws {
        var target = profile()
        target.redisDatabase = 3
        let session = RedisSession(profile: target, password: password)
        try await session.connect()
        defer { Task { await session.close() } }
        let id = try await session.call("CLIENT", "ID").int ?? 0
        // Drop it from another connection, as a server idle timeout would.
        let killer = RedisSession(profile: profile(), password: password)
        try await killer.connect()
        _ = try await killer.call("CLIENT", "KILL", "ID", String(id))
        await killer.close()
        try await Task.sleep(for: .milliseconds(200))
        let info = try await session.call("CLIENT", "INFO").string ?? ""
        #expect(info.contains(" db=3 "))
        #expect(await session.takeReconnectNotice())
    }

    @Test(.enabled(if: isConfigured && environment["SQPRO_REDIS_TLS_PORT"] != nil)) func tls() async throws {
        let port = Int(Self.environment["SQPRO_REDIS_TLS_PORT"] ?? "") ?? 0
        let session = RedisSession(profile: profile(port: port, tls: true), password: password)
        try await session.connect()
        #expect(try await session.call("PING") == .simple("PONG"))
        await session.close()
        // Plain text to a TLS port: the server hangs up (or never answers), and the message points at TLS.
        let plain = RedisSession(profile: profile(port: port), password: password, connectTimeout: .seconds(2))
        do {
            try await plain.connect()
            Issue.record("Plain text to a TLS port logged in")
        } catch let error as RedisError {
            #expect(error.localizedDescription.contains("turn TLS on") || error == .connectTimedOut)
        }
        // And TLS to a plain port.
        let address = Self.address ?? []
        let mismatch = RedisSession(profile: profile(port: Int(address.last ?? "") ?? 6379, tls: true), password: password, connectTimeout: .seconds(2))
        do {
            try await mismatch.connect()
            Issue.record("TLS to a plain port logged in")
        } catch let error as RedisError {
            #expect(error.localizedDescription.contains("turn TLS off") || error == .connectTimedOut)
        }
    }

    @Test(.enabled(if: isConfigured && environment["SQPRO_REDIS_ACL_USER"] != nil)) func aclUser() async throws {
        let session = RedisSession(
            profile: profile(user: Self.environment["SQPRO_REDIS_ACL_USER"] ?? ""),
            password: Self.environment["SQPRO_REDIS_ACL_PASSWORD"]
        )
        try await session.connect()
        defer { Task { await session.close() } }
        #expect(try await session.call("PING") == .simple("PONG"))
        // The test user is read-only: the server, not Query Pro, refuses the write.
        guard case .error(let message) = try await session.send("SET", "qp:test:acl", "x") else {
            Issue.record("The read-only ACL user could write")
            return
        }
        #expect(message.hasPrefix("NOPERM"))
    }
}
