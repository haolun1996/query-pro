import SwiftUI

@main
struct SQProApp: App {
    @State private var connections: ConnectionsModel
    @State private var workspace = Workspace()
    @State private var savedQueries = SavedQueriesModel()
    @State private var mcp: MCPController
    @State private var localServer = LocalServerController()

    init() {
        let connections = ConnectionsModel()
        _connections = State(initialValue: connections)
        _mcp = State(initialValue: MCPController(connections: connections))
    }

    var body: some Scene {
        Window("Query Pro", id: "main") {
            MainWindow()
                .environment(connections)
                .environment(workspace)
                .environment(mcp)
                .environment(savedQueries)
                .environment(localServer)
                .frame(minWidth: 900, minHeight: 520)
                #if DEBUG
                .task { await DebugSnapshot.run(workspace: workspace, connections: connections) }
                #endif
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands { QueryCommands(workspace: workspace) }

        Settings {
            SettingsView()
                .environment(mcp)
                .environment(connections)
        }

        Window("MCP Activity", id: MCPActivityView.windowID) {
            MCPActivityView()
                .environment(mcp)
                .environment(connections)
        }
        .defaultSize(width: 980, height: 420)
    }
}
