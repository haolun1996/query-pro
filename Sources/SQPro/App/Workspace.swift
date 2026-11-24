import Foundation
import Observation
import SQCore

/// What the tab strip needs from an open connection, MySQL or Redis.
protocol WorkspaceTab: AnyObject, Identifiable where ID == UUID {
    var profile: ConnectionProfile { get }
    var title: String { get }
    /// With the password saved in the Keychain.
    func connect() async
    func connect(password: String?) async
    func disconnect() async
}

extension WorkspaceTab {
    /// "GROUP/Name", like Workbench's connection tabs.
    var groupedTitle: String {
        guard let group = profile.groupName else { return profile.name }
        return "\(group)/\(profile.name)"
    }
}

/// The tabs of the main window: the home tab is always there, then one tab per open connection.
/// State lives here rather than in views, so switching tabs never drops a connection or a filter.
@Observable
final class Workspace {
    private(set) var tabs: [any WorkspaceTab] = []
    /// `nil` means the home tab.
    var selection: UUID?

    /// Home screen state, kept while other tabs are showing.
    var homeGroup: String?
    var homeFilter = ""

    var selected: (any WorkspaceTab)? {
        tabs.first { $0.id == selection }
    }

    /// The selected MySQL tab; menu commands (Run, Beautify …) only act on these.
    var selectedTab: ConnectionTab? {
        selected as? ConnectionTab
    }

    var selectedRedisTab: RedisTab? {
        selected as? RedisTab
    }

    /// Switches to the connection's tab if it is already open, otherwise opens a new one. `password` instead of the
    /// Keychain's is for throwaway debug connections.
    func open(_ profile: ConnectionProfile, password: String? = nil) {
        if let tab = tabs.first(where: { $0.profile.id == profile.id }) {
            selection = tab.id
            return
        }
        let tab: any WorkspaceTab = switch profile.kind {
        case .mysql: ConnectionTab(profile: profile)
        case .redis: RedisTab(profile: profile)
        }
        tabs.append(tab)
        selection = tab.id
        Task {
            if let password { await tab.connect(password: password) } else { await tab.connect() }
        }
    }

    func close(_ tab: any WorkspaceTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if selection == tab.id {
            // Like browsers: select the tab that took its place, else the one before, else home.
            selection = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
        Task { await tab.disconnect() }
    }
}
