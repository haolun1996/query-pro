import AppKit
import SwiftUI

/// Sidebar + detail with a draggable divider. Pure SwiftUI on purpose: `HSplitView` and the
/// `.sidebar` list style stretch the sidebar up into the title bar and cover the tab strip.
struct SidebarSplit<Sidebar: View, Detail: View>: View {
    @AppStorage("sidebarWidth") private var width: Double = 240
    @State private var dragStart: Double?
    @ViewBuilder let sidebar: Sidebar
    @ViewBuilder let detail: Detail

    private let range: ClosedRange<Double> = 180...480

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: width)
            Rectangle()
                .fill(.separator)
                .frame(width: 1)
                .overlay {
                    Color.clear
                        .frame(width: 9)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { NSCursor.columnResize.push() } else { NSCursor.pop() }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { drag in
                                    let start = dragStart ?? width
                                    dragStart = start
                                    width = min(
                                        max(start + drag.translation.width, range.lowerBound), range.upperBound)
                                }
                                .onEnded { _ in dragStart = nil }
                        )
                }
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Top + bottom with a draggable divider. The bottom height is remembered under `storageKey`.
/// With `showsBottom` false the top fills everything; the top keeps its identity either way,
/// so an editor inside it isn't rebuilt when the bottom appears.
struct VerticalSplit<Top: View, Bottom: View>: View {
    @AppStorage private var bottomHeight: Double
    @State private var dragStart: Double?
    let showsBottom: Bool
    let minTop: Double
    let minBottom: Double
    @ViewBuilder let top: Top
    @ViewBuilder let bottom: Bottom

    init(
        storageKey: String,
        defaultBottomHeight: Double,
        showsBottom: Bool = true,
        minTop: Double = 80,
        minBottom: Double = 60,
        @ViewBuilder top: () -> Top,
        @ViewBuilder bottom: () -> Bottom
    ) {
        _bottomHeight = AppStorage(wrappedValue: defaultBottomHeight, storageKey)
        self.showsBottom = showsBottom
        self.minTop = minTop
        self.minBottom = minBottom
        self.top = top()
        self.bottom = bottom()
    }

    var body: some View {
        GeometryReader { proxy in
            let maxBottom = max(minBottom, proxy.size.height - minTop)
            let height = min(max(bottomHeight, minBottom), maxBottom)
            VStack(spacing: 0) {
                top
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsBottom {
                    divider(height: height, maxBottom: maxBottom)
                    bottom
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                }
            }
        }
    }

    private func divider(height: Double, maxBottom: Double) -> some View {
        Rectangle()
            .fill(.separator)
            .frame(height: 1)
            .overlay {
                Color.clear
                    .frame(height: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.rowResize.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = dragStart ?? height
                                dragStart = start
                                bottomHeight = min(max(start - drag.translation.height, minBottom), maxBottom)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
    }
}
