import Foundation
import Observation
import SQCore

/// Saved queries, written to disk on every change.
@Observable
final class SavedQueriesModel {
    private(set) var queries: [SavedQuery] = []
    var lastError: String?

    private let store = SavedQueryStore()

    init() {
        do {
            queries = try store.load()
        } catch {
            lastError = "Couldn't read saved queries: \(error.localizedDescription)"
        }
    }

    /// This connection's queries and the ones shared by all connections, by name.
    func queries(for connection: UUID) -> [SavedQuery] {
        queries
            .filter { $0.connectionID == nil || $0.connectionID == connection }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func add(name: String, sql: String, connectionID: UUID?) {
        queries.append(SavedQuery(name: name, sql: sql, connectionID: connectionID))
        persist()
    }

    func update(_ query: SavedQuery) {
        guard let index = queries.firstIndex(where: { $0.id == query.id }) else { return }
        var query = query
        query.updatedAt = .now
        queries[index] = query
        persist()
    }

    func delete(_ query: SavedQuery) {
        queries.removeAll { $0.id == query.id }
        persist()
    }

    private func persist() {
        do {
            try store.save(queries)
            lastError = nil
        } catch {
            lastError = "Couldn't save queries: \(error.localizedDescription)"
        }
    }
}
