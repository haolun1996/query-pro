import Foundation
import Observation
import SQCore

/// The tabs of the main window: the home tab is always there, then one tab per open connection.
/// State lives here rather than in views, so switching tabs never drops a connection or a filter.
@Observable
final class Workspace {
    private(set) var tabs: [ConnectionTab] = []
    /// `nil` means the home tab.
    var selection: ConnectionTab.ID?

    /// Home screen state, kept while other tabs are showing.
    var homeGroup: String?
    var homeFilter = ""

    var selectedTab: ConnectionTab? {
        tabs.first { $0.id == selection }
    }

    /// Switches to the connection's tab if it is already open, otherwise opens a new one.
    func open(_ profile: ConnectionProfile) {
        if let tab = tabs.first(where: { $0.profile.id == profile.id }) {
            selection = tab.id
            return
        }
        let tab = ConnectionTab(profile: profile)
        tabs.append(tab)
        selection = tab.id
        Task { await tab.connect() }
    }

    func close(_ tab: ConnectionTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if selection == tab.id {
            // Like browsers: select the tab that took its place, else the one before, else home.
            selection = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
        Task { await tab.disconnect() }
    }
}
