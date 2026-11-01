import Foundation

/// One statement that was run, kept in the connection's history.
public struct HistoryEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var sql: String
    public var executedAt: Date
    /// The default schema it ran in.
    public var schema: String?
    public var succeeded: Bool
    /// "3 row(s) returned", or the error.
    public var response: String
    /// Seconds.
    public var duration: Double?

    public init(
        id: UUID = UUID(), sql: String, executedAt: Date = .now, schema: String?, succeeded: Bool, response: String,
        duration: Double?
    ) {
        self.id = id
        self.sql = sql
        self.executedAt = executedAt
        self.schema = schema
        self.succeeded = succeeded
        self.response = response
        self.duration = duration
    }
}

/// A connection's history as JSON Lines (`history/<connection id>.jsonl`), so each run only appends a line.
/// Keeps the newest `limit` entries.
public struct QueryHistoryStore: Sendable {
    public static let limit = 5000
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public init(connectionID: UUID) {
        self.init(fileURL: Self.directory.appending(path: "\(connectionID.uuidString).jsonl"))
    }

    public static var directory: URL {
        ConnectionStore.defaultURL.deletingLastPathComponent().appending(path: "history", directoryHint: .isDirectory)
    }

    /// Oldest first. Lines that can't be read are skipped. Trims the file once it's well past the limit.
    public func load() throws -> [HistoryEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let decoder = Self.decoder
        let entries = try String(contentsOf: fileURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { try? decoder.decode(HistoryEntry.self, from: Data($0.utf8)) }
        if entries.count > Self.limit + Self.limit / 5 {
            let kept = Array(entries.suffix(Self.limit))
            try save(kept)
            return kept
        }
        return Array(entries.suffix(Self.limit))
    }

    public func append(_ entries: [HistoryEntry]) throws {
        guard !entries.isEmpty else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try lines(entries)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL, options: .atomic)
        }
    }

    /// Rewrites the whole file, e.g. after deleting entries.
    public func save(_ entries: [HistoryEntry]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines(entries).write(to: fileURL, options: .atomic)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    /// Passwords in `IDENTIFIED BY '…'` and `SET PASSWORD = '…'` are replaced with `'***'` before anything is written.
    public static func redacted(_ sql: String) -> String {
        sql.replacing(passwordPattern) { match in "\(match.output.1)'***'" }
    }

    nonisolated(unsafe) private static let passwordPattern =
        /(?i)(IDENTIFIED\s+(?:WITH\s+\S+\s+)?(?:BY|AS)\s+|SET\s+PASSWORD(?:\s+FOR\s+\S+)?\s*=\s*(?:PASSWORD\s*\(\s*)?)'(?:[^'\\]|\\.|'')*'/

    private func lines(_ entries: [HistoryEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for entry in entries {
            data += try encoder.encode(entry)
            data += Data("\n".utf8)
        }
        return data
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
