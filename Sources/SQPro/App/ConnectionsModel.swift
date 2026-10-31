import Foundation
import Observation
import SQCore

/// All saved connections. Every change is written to disk straight away.
@Observable
final class ConnectionsModel {
    private(set) var profiles: [ConnectionProfile] = []
    var lastError: String?

    private let store = ConnectionStore()

    init() {
        do {
            profiles = try store.load()
        } catch {
            lastError = "Couldn't read saved connections: \(error.localizedDescription)"
        }
    }

    var groups: [String] {
        Set(profiles.compactMap(\.groupName)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func profile(id: UUID) -> ConnectionProfile? {
        profiles.first { $0.id == id }
    }

    func profiles(inGroup group: String?) -> [ConnectionProfile] {
        profiles.filter { $0.groupName == group }
    }

    /// Searches every group, matching name, group, user, host and schema.
    func search(_ text: String) -> [ConnectionProfile] {
        let terms = text.split(separator: " ").map(String.init)
        return profiles.filter { profile in
            let haystack = [profile.name, profile.groupName ?? "", profile.user, profile.address, profile.defaultSchema]
                .joined(separator: " ")
            return terms.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
        }
    }

    /// Adds the profile, or replaces the saved one with the same id.
    func save(_ profile: ConnectionProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        persist()
    }

    /// Remembers the row limit dropdown per connection. `nil` = Don't Limit.
    func setRowLimit(_ limit: Int?, for id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].rowLimit = limit
        persist()
    }

    func duplicate(_ profile: ConnectionProfile) {
        var copy = profile
        copy.id = UUID()
        copy.name = "\(profile.name) copy"
        Task {
            if let password = await Keychain.password(for: profile.id) {
                await Keychain.setPassword(password, for: copy.id)
            }
        }
        let index = profiles.firstIndex { $0.id == profile.id }.map { $0 + 1 } ?? profiles.endIndex
        profiles.insert(copy, at: index)
        persist()
    }

    func delete(_ profile: ConnectionProfile) {
        profiles.removeAll { $0.id == profile.id }
        Task { await Keychain.deletePassword(for: profile.id) }
        persist()
    }

    func move(_ id: UUID, toGroup group: String?) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].group = group
        persist()
    }

    func renameGroup(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        for index in profiles.indices where profiles[index].groupName == old {
            profiles[index].group = name
        }
        persist()
    }

    /// Removes the group but keeps its connections, moving them to the home screen.
    func ungroup(_ group: String) {
        for index in profiles.indices where profiles[index].groupName == group {
            profiles[index].group = nil
        }
        persist()
    }

    private func persist() {
        do {
            try store.save(profiles)
            lastError = nil
        } catch {
            lastError = "Couldn't save connections: \(error.localizedDescription)"
        }
    }
}
