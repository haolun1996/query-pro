import AppKit
import SwiftUI
import SQCore

/// The row of tabs in the title bar: 🏠 first, then one per open connection.
struct TabStrip: View {
    @Environment(Workspace.self) private var workspace

    /// Room for the window's close / minimise / zoom buttons.
    static let trafficLightInset: CGFloat = 78
    static let height: CGFloat = 30

    var body: some View {
        HStack(spacing: 2) {
            TabItem(isSelected: workspace.selection == nil, onClose: nil) {
                workspace.selection = nil
            } label: {
                Image(systemName: "house.fill")
                    .frame(width: 28)
            }
            .help("Home")

            ForEach(workspace.tabs) { tab in
                TabItem(isSelected: workspace.selection == tab.id, onClose: { workspace.close(tab) }) {
                    workspace.selection = tab.id
                } label: {
                    HStack(spacing: 6) {
                        if let color = tab.profile.color.color {
                            Circle().fill(color).frame(width: 7, height: 7)
                        }
                        Text(tab.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(minWidth: 80, maxWidth: 240)
                }
                .help(tab.title)
                .contextMenu {
                    Button("Close Tab") { workspace.close(tab) }
                    Button("Close Other Tabs") {
                        for other in workspace.tabs where other.id != tab.id { workspace.close(other) }
                    }
                }
            }

            // Empty space behaves like a normal title bar: drag to move, double-click to zoom.

            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .simultaneousGesture(TapGesture(count: 2).onEnded(Self.titleBarDoubleClick))
                .allowsWindowActivationEvents(true)
        }
        .font(.callout)
        .padding(.leading, Self.trafficLightInset)
        .padding(.trailing, 8)
        .frame(height: Self.height)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

extension TabStrip {
    /// Does what System Settings › Desktop & Dock › "Double-click a window's title bar to" says.
    static func titleBarDoubleClick() {
        guard let window = NSApp.keyWindow else { return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)  // "Maximize" / "Fill", and the default when never changed
        }
    }
}

private struct TabItem<Label: View>: View {
    let isSelected: Bool
    /// `nil` for the home tab, which can't be closed.
    let onClose: (() -> Void)?
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            label
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(isHovering || isSelected ? 1 : 0)
                .help("Close tab")
            }
        }
        .padding(.leading, onClose == nil ? 4 : 10)
        .padding(.trailing, 4)
        .frame(height: TabStrip.height - 6)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular, in: .rect(cornerRadius: 7, style: .continuous))
            } else if isHovering {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.primary.opacity(0.06))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { isHovering = $0 }
    }
}
