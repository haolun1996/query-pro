import Foundation

/// Saves connection profiles as JSON in Application Support. Passwords live in the Keychain, never here.
public struct ConnectionStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = ConnectionStore.defaultURL) {
        self.fileURL = fileURL
    }

    public static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "SQPro", directoryHint: .isDirectory)
            .appending(path: "connections.json")
    }

    public func load() throws -> [ConnectionProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([ConnectionProfile].self, from: data)
    }

    public func save(_ profiles: [ConnectionProfile]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: fileURL, options: .atomic)
    }
}
