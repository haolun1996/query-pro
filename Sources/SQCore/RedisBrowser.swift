import Foundation

/// A key as the browser lists it.
public struct RedisKey: Hashable, Sendable {
    public let name: Data
    /// `string`, `hash`, `list`, `set`, `zset`, `stream`, or a module type such as `ReJSON-RL`.
    public var type: String
    /// Milliseconds left; `nil` = no expiry.
    public var ttl: Int64?

    public init(name: Data, type: String, ttl: Int64?) {
        self.name = name
        self.type = type
        self.ttl = ttl
    }

    public var displayName: String { RedisCommand.display(name) }
}

/// A key's value, loaded up to a limit so a huge list can't freeze the app.
public enum RedisValue: Equatable, Sendable {
    public struct StreamEntry: Equatable, Sendable {
        public let id: String
        public let fields: [(Data, Data)]

        public static func == (a: Self, b: Self) -> Bool {
            a.id == b.id && a.fields.map(\.0) == b.fields.map(\.0) && a.fields.map(\.1) == b.fields.map(\.1)
        }
    }

    case string(Data)
    case hash([(field: Data, value: Data)])
    case list([Data])
    case set([Data])
    case zset([(member: Data, score: String)])
    case stream([StreamEntry])
    /// A type Query Pro has no viewer for; the console can still read it.
    case other(String)

    public static func == (a: Self, b: Self) -> Bool {
        switch (a, b) {
        case (.string(let x), .string(let y)): x == y
        case (.hash(let x), .hash(let y)): x.map(\.field) == y.map(\.field) && x.map(\.value) == y.map(\.value)
        case (.list(let x), .list(let y)), (.set(let x), .set(let y)): x == y
        case (.zset(let x), .zset(let y)): x.map(\.member) == y.map(\.member) && x.map(\.score) == y.map(\.score)
        case (.stream(let x), .stream(let y)): x == y
        case (.other(let x), .other(let y)): x == y
        default: false
        }
    }

    /// Items shown: characters are not counted for strings.
    public var count: Int {
        switch self {
        case .string, .other: 1
        case .hash(let items): items.count
        case .list(let items), .set(let items): items.count
        case .zset(let items): items.count
        case .stream(let items): items.count
        }
    }
}

public struct RedisLoadedValue: Sendable {
    public let value: RedisValue
    /// Elements in the key (bytes for strings); more than `value.count` when it was cut at the limit.
    public let total: Int64
    public var isTruncated: Bool { total > Int64(value.count) && !(value.isString) }
}

extension RedisValue {
    var isString: Bool {
        if case .string = self { return true }
        return false
    }
}

public enum RedisBrowser {
    public static let defaultLimit = 1000

    /// One SCAN step. Keys come back unsorted and may repeat across steps, as Redis documents.
    public static func scan(
        _ session: RedisSession,
        cursor: String,
        pattern: String,
        count: Int = 500,
        type: String? = nil
    ) async throws -> (cursor: String, keys: [Data]) {
        var arguments = ["SCAN", cursor, "MATCH", pattern.isEmpty ? "*" : pattern, "COUNT", String(count)]
        if let type { arguments += ["TYPE", type] }
        let reply = try await session.call(arguments.map { Data($0.utf8) })
        guard let parts = reply.array, parts.count == 2, let next = parts[0].string else {
            throw RESP.ProtocolError(message: "SCAN reply")
        }
        return (next, (parts[1].array ?? []).compactMap(\.data))
    }

    /// TYPE and PTTL for many keys in one round trip. Keys that vanished meanwhile (type `none`) are left out.
    public static func describe(_ session: RedisSession, _ names: [Data]) async throws -> [RedisKey] {
        guard !names.isEmpty else { return [] }
        var commands: [[Data]] = []
        for name in names {
            commands.append([Data("TYPE".utf8), name])
            commands.append([Data("PTTL".utf8), name])
        }
        let replies = try await session.sendAll(commands)
        var keys: [RedisKey] = []
        for (index, name) in names.enumerated() {
            let type = replies[index * 2].string ?? "none"
            guard type != "none" else { continue }
            let ttl = replies[index * 2 + 1].int.flatMap { $0 >= 0 ? $0 : nil }
            keys.append(RedisKey(name: name, type: type, ttl: ttl))
        }
        return keys
    }

    /// Up to `limit` elements: lists and sorted sets from the start, hashes and sets in SCAN order, streams newest first.
    public static func load(_ session: RedisSession, key: Data, type: String, limit: Int = defaultLimit) async throws -> RedisLoadedValue {
        func call(_ words: String..., then extra: [Data] = []) async throws -> RESPValue {
            let arguments = [Data(words[0].utf8), key] + words.dropFirst().map { Data($0.utf8) } + extra
            return try await session.call(arguments)
        }
        let last = String(max(limit, 1) - 1)
        switch type {
        case "string":
            let data = try await call("GET").data ?? Data()
            return RedisLoadedValue(value: .string(data), total: Int64(data.count))
        case "list":
            let total = try await call("LLEN").int ?? 0
            let items = try await call("LRANGE", "0", last).array?.compactMap(\.data) ?? []
            return RedisLoadedValue(value: .list(items), total: total)
        case "hash":
            let total = try await call("HLEN").int ?? 0
            let flat = try await scanAll(session, command: "HSCAN", key: key, limit: limit * 2)
            let pairs = stride(from: 0, to: flat.count - 1, by: 2).map { (field: flat[$0], value: flat[$0 + 1]) }
            return RedisLoadedValue(value: .hash(Array(pairs.prefix(limit))), total: total)
        case "set":
            let total = try await call("SCARD").int ?? 0
            let members = try await scanAll(session, command: "SSCAN", key: key, limit: limit)
            return RedisLoadedValue(value: .set(Array(Set(members)).sorted { $0.lexicographicallyPrecedes($1) }.prefix(limit).map { $0 }), total: total)
        case "zset":
            let total = try await call("ZCARD").int ?? 0
            let flat = try await call("ZRANGE", "0", last, "WITHSCORES").array?.compactMap(\.data) ?? []
            let pairs = stride(from: 0, to: flat.count - 1, by: 2).map { (member: flat[$0], score: String(decoding: flat[$0 + 1], as: UTF8.self)) }
            return RedisLoadedValue(value: .zset(pairs), total: total)
        case "stream":
            let total = try await call("XLEN").int ?? 0
            let entries = try await call("XREVRANGE", "+", "-", "COUNT", String(limit)).array ?? []
            return RedisLoadedValue(value: .stream(entries.compactMap(streamEntry)), total: total)
        default:
            return RedisLoadedValue(value: .other(type), total: 0)
        }
    }

    private static func streamEntry(_ value: RESPValue) -> RedisValue.StreamEntry? {
        guard let parts = value.array, parts.count == 2, let id = parts[0].string else { return nil }
        let flat = parts[1].array?.compactMap(\.data) ?? []
        return .init(id: id, fields: stride(from: 0, to: flat.count - 1, by: 2).map { (flat[$0], flat[$0 + 1]) })
    }

    /// HSCAN / SSCAN until done or `limit` items (a hash's fields and values both count).
    private static func scanAll(_ session: RedisSession, command: String, key: Data, limit: Int) async throws -> [Data] {
        var cursor = "0"
        var items: [Data] = []
        repeat {
            let reply = try await session.call([Data(command.utf8), key, Data(cursor.utf8), Data("COUNT".utf8), Data("500".utf8)])
            guard let parts = reply.array, parts.count == 2, let next = parts[0].string else {
                throw RESP.ProtocolError(message: "\(command) reply")
            }
            items += (parts[1].array ?? []).compactMap(\.data)
            cursor = next
        } while cursor != "0" && items.count < limit
        return items
    }

    /// Databases and their key counts from `INFO keyspace`, e.g. `db0:keys=12,expires=0,avg_ttl=0`.
    public static func keyspace(_ info: String) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for line in info.split(whereSeparator: \.isNewline) where line.hasPrefix("db") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let number = Int(parts[0].dropFirst(2)) else { continue }
            let keys = parts[1].split(separator: ",").first { $0.hasPrefix("keys=") }.flatMap { Int($0.dropFirst(5)) }
            counts[number] = keys ?? 0
        }
        return counts
    }

    /// One field of an `INFO` reply, e.g. `redis_version`.
    public static func infoField(_ name: String, in info: String) -> String? {
        for line in info.split(whereSeparator: \.isNewline) where line.hasPrefix(name + ":") {
            return String(line.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// "1d 3h", "12m 5s", "40s": a TTL the way people read it.
    public static func formatTTL(milliseconds: Int64) -> String {
        let seconds = milliseconds / 1000
        if seconds < 1 { return "\(milliseconds)ms" }
        let (d, h, m, s) = (seconds / 86400, seconds % 86400 / 3600, seconds % 3600 / 60, seconds % 60)
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        if m > 0 { return s > 0 ? "\(m)m \(s)s" : "\(m)m" }
        return "\(s)s"
    }
}

/// Keys grouped into folders by a separator, like `user:42:name` under `user` › `42`.
public struct RedisKeyNode: Identifiable, Hashable, Sendable {
    /// `f:<prefix>` for folders, `k:<key>` for keys, so a key and a folder with the same name can sit side by side.
    public let id: String
    public let name: String
    /// Set for keys.
    public let key: RedisKey?
    /// `nil` for keys, so SwiftUI's outline shows no disclosure triangle.
    public var children: [RedisKeyNode]?
    /// Keys inside a folder, counting subfolders.
    public var keyCount: Int

    public static func tree(_ keys: [RedisKey], separator: String = ":") -> [RedisKeyNode] {
        final class Folder {
            var folders: [String: Folder] = [:]
            var keys: [RedisKey] = []
        }
        let root = Folder()
        for key in keys {
            var parts = separator.isEmpty ? [key.displayName] : key.displayName.components(separatedBy: separator)
            // A trailing or empty segment ("a:", "a::b") stays part of the key's own name rather than a nameless folder.
            if parts.count > 1, parts.dropLast().contains(where: \.isEmpty) { parts = [key.displayName] }
            var folder = root
            for part in parts.dropLast() {
                if folder.folders[part] == nil { folder.folders[part] = Folder() }
                folder = folder.folders[part]!
            }
            folder.keys.append(key)
        }
        func nodes(_ folder: Folder, prefix: String) -> [RedisKeyNode] {
            let subfolders = folder.folders.map { name, child -> RedisKeyNode in
                let children = nodes(child, prefix: prefix + name + separator)
                return RedisKeyNode(
                    id: "f:" + prefix + name, name: name, key: nil, children: children,
                    keyCount: children.reduce(0) { $0 + ($1.key == nil ? $1.keyCount : 1) }
                )
            }
            let leaves = folder.keys.map { key in
                let full = key.displayName
                let name = full.hasPrefix(prefix) && full.count > prefix.count ? String(full.dropFirst(prefix.count)) : full
                return RedisKeyNode(id: "k:" + full, name: name, key: key, children: nil, keyCount: 1)
            }
            let order: (String, String) -> Bool = { $0.localizedStandardCompare($1) == .orderedAscending }
            return subfolders.sorted { order($0.name, $1.name) } + leaves.sorted { order($0.name, $1.name) }
        }
        return nodes(root, prefix: "")
    }
}
