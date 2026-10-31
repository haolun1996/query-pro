#if DEBUG
import AppKit
import SwiftUI
import SQCore

/// Debug-only: lets a script drive the app and capture the window without Screen Recording permission.
///
///     SQPRO_OPEN="Local POS"          open this saved connection
///     SQPRO_OPEN_TEMP=root@localhost:3306   or a throwaway one that is never saved
///     SQPRO_SQL="select 1;"           put this in the editor and run it
///     SQPRO_TABLE_INFO=pos.admins     open that table's info tab
///     SQPRO_TABLE_SECTION=Indexes     …on this section
///     SQPRO_SNAPSHOT=/path/out.png    save the window as a PNG, then quit
///     SQPRO_SNAPSHOT_DELAY=4          seconds to wait first (default 4)
enum DebugSnapshot {
    @MainActor
    static func run(workspace: Workspace, connections: ConnectionsModel) async {
        let environment = ProcessInfo.processInfo.environment
        var target = environment["SQPRO_OPEN"].flatMap { name in connections.profiles.first { $0.name == name } }
        if let spec = environment["SQPRO_OPEN_TEMP"], let at = spec.firstIndex(of: "@") {
            let address = spec[spec.index(after: at)...].split(separator: ":")
            target = ConnectionProfile(
                name: "Temp \(spec)",
                host: String(address.first ?? "localhost"),
                port: address.count > 1 ? Int(address[1]) ?? 3306 : 3306,
                user: String(spec[..<at])
            )
        }
        if let profile = target {
            workspace.open(profile)
            if let sql = environment["SQPRO_SQL"], let tab = workspace.selectedTab {
                for _ in 0..<50 where !isConnected(tab) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                tab.selectedQuery?.text = sql
                tab.run(.all)
            }
            if let target = environment["SQPRO_TABLE_INFO"], let tab = workspace.selectedTab {
                for _ in 0..<50 where !isConnected(tab) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let parts = target.split(separator: ".").map(String.init)
                if parts.count == 2, let schema = tab.schemaNode(parts[0]) {
                    await tab.loadObjects(of: schema)
                    if let table = tab.tableNode(parts[0], parts[1]) {
                        tab.openTableInfo(table, in: schema)
                        if let section = environment["SQPRO_TABLE_SECTION"].flatMap(TableInfo.Section.init(rawValue:)) {
                            tab.selectedQuery?.tableInfo?.section = section
                        }
                    }
                }
            }
        }
        guard let path = environment["SQPRO_SNAPSHOT"] else { return }
        let delay = Double(environment["SQPRO_SNAPSHOT_DELAY"] ?? "") ?? 4
        try? await Task.sleep(for: .seconds(delay))
        save(to: URL(fileURLWithPath: path))
        NSApp.terminate(nil)
    }

    private static func isConnected(_ tab: ConnectionTab) -> Bool {
        if case .connected = tab.state { return true }
        return false
    }

    @MainActor
    private static func save(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
