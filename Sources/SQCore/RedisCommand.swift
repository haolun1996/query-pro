import Foundation

/// Typing, showing and judging Redis commands: the console's `redis-cli` syntax, `redis-cli`-style replies, and which
/// commands AI clients may run.
public enum RedisCommand {
    public struct SyntaxError: Error, LocalizedError {
        public var errorDescription: String? { "Invalid argument(s): unbalanced quotes." }
    }

    // MARK: Parsing

    /// Splits a console line like `redis-cli` does: spaces separate arguments, "double quotes" take `\n \r \t \b \a
    /// \\ \" \xHH` escapes, 'single quotes' only `\'`. A closing quote must end the argument.
    public static func parse(_ line: String) throws -> [Data] {
        let bytes = Array(line.utf8)
        var arguments: [Data] = []
        var index = 0
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }
        while true {
            while index < bytes.count, isSpace(bytes[index]) { index += 1 }
            guard index < bytes.count else { return arguments }
            var current: [UInt8] = []
            var inDouble = false
            var inSingle = false
            argument: while true {
                if inDouble {
                    guard index < bytes.count else { throw SyntaxError() }
                    let byte = bytes[index]
                    if byte == UInt8(ascii: "\\"), index + 3 < bytes.count, bytes[index + 1] == UInt8(ascii: "x"),
                       let high = hexValue(bytes[index + 2]), let low = hexValue(bytes[index + 3]) {
                        current.append(high << 4 | low)
                        index += 3
                    } else if byte == UInt8(ascii: "\\"), index + 1 < bytes.count {
                        index += 1
                        switch bytes[index] {
                        case UInt8(ascii: "n"): current.append(0x0A)
                        case UInt8(ascii: "r"): current.append(0x0D)
                        case UInt8(ascii: "t"): current.append(0x09)
                        case UInt8(ascii: "b"): current.append(0x08)
                        case UInt8(ascii: "a"): current.append(0x07)
                        default: current.append(bytes[index])
                        }
                    } else if byte == UInt8(ascii: "\"") {
                        // The closing quote must be followed by a space or the end.
                        if index + 1 < bytes.count, !isSpace(bytes[index + 1]) { throw SyntaxError() }
                        index += 1
                        break argument
                    } else {
                        current.append(byte)
                    }
                    index += 1
                } else if inSingle {
                    guard index < bytes.count else { throw SyntaxError() }
                    let byte = bytes[index]
                    if byte == UInt8(ascii: "\\"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "'") {
                        current.append(UInt8(ascii: "'"))
                        index += 1
                    } else if byte == UInt8(ascii: "'") {
                        if index + 1 < bytes.count, !isSpace(bytes[index + 1]) { throw SyntaxError() }
                        index += 1
                        break argument
                    } else {
                        current.append(byte)
                    }
                    index += 1
                } else {
                    guard index < bytes.count, !isSpace(bytes[index]) else { break argument }
                    switch bytes[index] {
                    case UInt8(ascii: "\""): inDouble = true
                    case UInt8(ascii: "'"): inSingle = true
                    default: current.append(bytes[index])
                    }
                    index += 1
                }
            }
            arguments.append(Data(current))
        }
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    // MARK: Showing

    /// A reply the way `redis-cli` prints it: `"text"`, `(integer) 5`, `(nil)`, `(error) …`, numbered nested lists.
    public static func format(_ value: RESPValue) -> String {
        formatLines(value).joined(separator: "\n")
    }

    private static func formatLines(_ value: RESPValue) -> [String] {
        switch value {
        case .simple(let text): return [text]
        case .error(let text): return ["(error) \(text)"]
        case .integer(let number): return ["(integer) \(number)"]
        case .bulk(nil), .array(nil): return ["(nil)"]
        case .bulk(let data?): return [quote(data)]
        case .array(let items?):
            guard !items.isEmpty else { return ["(empty array)"] }
            let width = String(items.count).count
            var lines: [String] = []
            for (offset, item) in items.enumerated() {
                let number = String(offset + 1)
                let label = String(repeating: " ", count: width - number.count) + number + ") "
                let indent = String(repeating: " ", count: label.count)
                for (index, line) in formatLines(item).enumerated() {
                    lines.append((index == 0 ? label : indent) + line)
                }
            }
            return lines
        }
    }

    /// Double-quoted with escapes, so the text can be typed back into the console. Valid UTF-8 keeps its letters;
    /// other bytes become `\xHH`.
    public static func quote(_ data: Data) -> String {
        "\"" + escape(data) + "\""
    }

    /// Text for a value or key: as is when it's printable UTF-8, otherwise escaped like `quote` (without quotes).
    public static func display(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8), !text.unicodeScalars.contains(where: isControl) { return text }
        return escape(data)
    }

    /// `true` when `display` had to escape it, so editing the shown text would change the value.
    public static func isBinary(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return true }
        return text.unicodeScalars.contains { isControl($0) && $0 != "\n" && $0 != "\t" && $0 != "\r" }
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }

    private static func escape(_ data: Data) -> String {
        var out = ""
        if let text = String(data: data, encoding: .utf8) {
            for scalar in text.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                case _ where isControl(scalar): out += String(format: "\\x%02x", scalar.value)
                default: out.unicodeScalars.append(scalar)
                }
            }
            return out
        }
        for byte in data {
            switch byte {
            case UInt8(ascii: "\""): out += "\\\""
            case UInt8(ascii: "\\"): out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x20..<0x7F: out.unicodeScalars.append(Unicode.Scalar(byte))
            default: out += String(format: "\\x%02x", byte)
            }
        }
        return out
    }

    // MARK: Judging

    public enum Access: Equatable, Sendable {
        case read
        case write
        /// Never run for AI clients, whatever the connection allows. The reason says what to do instead.
        case refused(String)
    }

    /// What a command does, for AI clients. Unknown commands count as writes, so a read-only connection never runs
    /// something it doesn't know.
    public static func access(_ arguments: [String]) -> Access {
        guard let first = arguments.first else { return .refused("Empty command.") }
        let name = first.uppercased()
        let sub = arguments.count > 1 ? arguments[1].uppercased() : ""
        let rest = arguments.dropFirst().map { $0.uppercased() }

        if let reason = refused[name] { return .refused(reason) }
        if blocking.contains(name) { return .refused("\(name) waits for data and would hold the connection; use the non-blocking form.") }
        if (name == "XREAD" || name == "XREADGROUP"), rest.contains("BLOCK") {
            return .refused("\(name) with BLOCK would hold the connection; leave out BLOCK.")
        }
        if let reads = containerReads[name] {
            if reads.contains(sub) { return .read }
            if name == "CLIENT" { return .refused("CLIENT \(sub) changes connections; only CLIENT INFO / GETNAME / ID are allowed.") }
            return .write
        }
        return reads.contains(name) ? .read : .write
    }

    /// On production (red) connections the console asks before these: they wipe or stop a whole server.
    public static func needsConfirmation(_ arguments: [String]) -> Bool {
        guard let name = arguments.first?.uppercased() else { return false }
        let sub = arguments.count > 1 ? arguments[1].uppercased() : ""
        switch name {
        case "FLUSHALL", "FLUSHDB", "SHUTDOWN", "SWAPDB", "DEBUG", "KEYS", "MIGRATE", "REPLICAOF", "SLAVEOF", "FAILOVER":
            return true
        case "CONFIG": return sub != "GET"
        case "ACL": return !["LIST", "USERS", "WHOAMI", "GETUSER", "CAT", "LOG"].contains(sub)
        default: return false
        }
    }

    private static let refused: [String: String] = {
        var map: [String: String] = [:]
        for name in ["FLUSHALL", "FLUSHDB", "SWAPDB", "SHUTDOWN", "DEBUG", "CONFIG", "ACL", "REPLICAOF", "SLAVEOF", "FAILOVER",
                     "CLUSTER", "MODULE", "MIGRATE", "SAVE", "BGSAVE", "BGREWRITEAOF", "SYNC", "PSYNC", "LATENCY", "SLOWLOG"] {
            map[name] = "\(name) is a server administration command; Query Pro never runs it for AI clients."
        }
        for name in ["MONITOR", "SUBSCRIBE", "PSUBSCRIBE", "SSUBSCRIBE", "UNSUBSCRIBE", "PUNSUBSCRIBE", "SUNSUBSCRIBE"] {
            map[name] = "\(name) streams messages forever and can't run as one tool call."
        }
        for name in ["EVAL", "EVALSHA", "EVAL_RO", "EVALSHA_RO", "FCALL", "FCALL_RO", "SCRIPT", "FUNCTION"] {
            map[name] = "Scripts can run any command, so \(name) isn't allowed for AI clients; send the commands one by one."
        }
        for name in ["MULTI", "EXEC", "DISCARD", "WATCH", "UNWATCH"] {
            map[name] = "Each tool call is one command on its own connection, so transactions (\(name)) can't span calls."
        }
        for name in ["SELECT", "AUTH", "HELLO", "RESET", "QUIT"] {
            map[name] = "\(name) changes the connection itself; pass database to the tool instead of SELECT."
        }
        map["KEYS"] = "KEYS blocks the server while it walks every key; use scan_keys instead."
        map["WAIT"] = "WAIT blocks for replicas and isn't useful from a tool call."
        map["WAITAOF"] = map["WAIT"]
        return map
    }()

    private static let blocking: Set<String> = [
        "BLPOP", "BRPOP", "BLMOVE", "BRPOPLPUSH", "BLMPOP", "BZPOPMIN", "BZPOPMAX", "BZMPOP",
    ]

    /// Commands with subcommands: the subcommands that only read. Any other subcommand is a write.
    private static let containerReads: [String: Set<String>] = [
        "OBJECT": ["ENCODING", "FREQ", "IDLETIME", "REFCOUNT", "HELP"],
        "MEMORY": ["USAGE", "STATS", "DOCTOR", "MALLOC-STATS", "HELP"],
        "XINFO": ["STREAM", "GROUPS", "CONSUMERS", "HELP"],
        "COMMAND": ["", "COUNT", "INFO", "DOCS", "LIST", "GETKEYS", "GETKEYSANDFLAGS", "HELP"],
        "CLIENT": ["INFO", "GETNAME", "ID"],
        "PUBSUB": ["CHANNELS", "NUMSUB", "NUMPAT", "SHARDCHANNELS", "SHARDNUMSUB", "HELP"],
    ]

    private static let reads: Set<String> = [
        // Keys and server
        "EXISTS", "TYPE", "TTL", "PTTL", "EXPIRETIME", "PEXPIRETIME", "DBSIZE", "SCAN", "RANDOMKEY", "DUMP", "PING", "ECHO",
        "TIME", "INFO", "LASTSAVE", "ROLE", "SORT_RO", "LOLWUT",
        // Strings and bits
        "GET", "MGET", "GETRANGE", "SUBSTR", "STRLEN", "LCS", "BITCOUNT", "BITPOS", "GETBIT", "BITFIELD_RO",
        // Hashes
        "HGET", "HMGET", "HGETALL", "HKEYS", "HVALS", "HLEN", "HEXISTS", "HSTRLEN", "HRANDFIELD", "HSCAN", "HTTL", "HPTTL",
        "HEXPIRETIME", "HPEXPIRETIME",
        // Lists
        "LRANGE", "LLEN", "LINDEX", "LPOS",
        // Sets
        "SMEMBERS", "SISMEMBER", "SMISMEMBER", "SCARD", "SRANDMEMBER", "SINTER", "SUNION", "SDIFF", "SINTERCARD", "SSCAN",
        // Sorted sets
        "ZRANGE", "ZRANGEBYSCORE", "ZREVRANGEBYSCORE", "ZRANGEBYLEX", "ZREVRANGEBYLEX", "ZREVRANGE", "ZSCORE", "ZMSCORE",
        "ZCARD", "ZCOUNT", "ZLEXCOUNT", "ZRANK", "ZREVRANK", "ZRANDMEMBER", "ZINTER", "ZUNION", "ZDIFF", "ZINTERCARD", "ZSCAN",
        // Streams (XREADGROUP writes: it records deliveries)
        "XRANGE", "XREVRANGE", "XLEN", "XPENDING", "XREAD",
        // HyperLogLog and geo
        "PFCOUNT", "GEOPOS", "GEODIST", "GEOHASH", "GEOSEARCH", "GEORADIUS_RO", "GEORADIUSBYMEMBER_RO",
        // Modules: RedisJSON and search
        "JSON.GET", "JSON.MGET", "JSON.TYPE", "JSON.STRLEN", "JSON.OBJKEYS", "JSON.OBJLEN", "JSON.ARRLEN", "JSON.ARRINDEX",
        "JSON.RESP", "FT.SEARCH", "FT.AGGREGATE", "FT.INFO", "FT._LIST", "FT.EXPLAIN",
    ]
}
