import Foundation

/// A named query kept in Query Pro, for one connection or for all of them.
public struct SavedQuery: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var sql: String
    /// `nil` = shown for every connection.
    public var connectionID: UUID?
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, sql: String, connectionID: UUID? = nil, updatedAt: Date = .now) {
        self.id = id
        self.name = name
        self.sql = sql
        self.connectionID = connectionID
        self.updatedAt = updatedAt
    }
}

/// Saves the saved queries as JSON next to connections.json.
public struct SavedQueryStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = SavedQueryStore.defaultURL) {
        self.fileURL = fileURL
    }

    public static var defaultURL: URL {
        ConnectionStore.defaultURL.deletingLastPathComponent().appending(path: "saved-queries.json")
    }

    public func load() throws -> [SavedQuery] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([SavedQuery].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ queries: [SavedQuery]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(queries).write(to: fileURL, options: .atomic)
    }
}
