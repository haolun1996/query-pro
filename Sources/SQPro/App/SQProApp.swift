import SwiftUI

@main
struct SQProApp: App {
    @State private var connections = ConnectionsModel()
    @State private var workspace = Workspace()

    var body: some Scene {
        Window("SQ Pro", id: "main") {
            MainWindow()
                .environment(connections)
                .environment(workspace)
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
        }
    }
}
