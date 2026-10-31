import SwiftUI

/// The single app window: tab strip in the title bar, then the selected tab's content.
struct MainWindow: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            TabStrip()
                .zIndex(1)
            Group {
                if let tab = workspace.selectedTab {
                    ConnectionTabView(tab: tab)
                        .id(tab.id)
                } else {
                    HomeView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}
