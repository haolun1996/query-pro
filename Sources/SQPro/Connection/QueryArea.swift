import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SQCore

/// Right side of a connection tab: query tabs, toolbar, editor, results and Action Output.
struct QueryArea: View {
    @Bindable var tab: ConnectionTab
    @Environment(ConnectionsModel.self) private var connections

    static let rowLimits: [Int?] = [nil, 10, 50, 100, 200, 300, 400, 500, 1000, 2000, 5000, 10000, 50000]

    var body: some View {
        // Results and Action Output stay hidden until there is something to show.
        VerticalSplit(storageKey: "actionOutputHeight", defaultBottomHeight: 150, showsBottom: !tab.log.isEmpty) {
            VerticalSplit(
                storageKey: "resultsHeight",
                defaultBottomHeight: 260,
                showsBottom: tab.selectedQuery?.results.isEmpty == false,
                minTop: 120
            ) {
                VStack(spacing: 0) {
                    QueryTabBar(tab: tab)
                    if let info = tab.selectedQuery?.tableInfo {
                        Divider()
                        TableInfoView(info: info) { Task { await tab.loadTableInfo(info) } }
                    } else {
                        toolbar
                        Divider()
                        if let document = tab.selectedQuery {
                            SQLEditor(document: document)
                                .id(document.id)
                        }
                    }
                }
            } bottom: {
                if let document = tab.selectedQuery {
                    ResultsPanel(document: document)
                }
            }
        } bottom: {
            ActionOutputView(tab: tab)
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 2) {
            ToolbarButton("Open SQL File (⌘O)", icon: "folder") { QueryFiles.open(into: tab) }
            ToolbarButton("Save Query (⌘S)", icon: "square.and.arrow.down") { QueryFiles.save(tab.selectedQuery) }
            separator
            ToolbarButton("Execute all, or the selection (⇧⌘↩)", icon: "bolt.fill", tint: .yellow) { tab.run(.all) }
                .disabled(tab.isRunning)
            ToolbarButton("Execute the statement under the cursor (⌘↩)", icon: "bolt.horizontal.fill", tint: .yellow) { tab.run(.current) }
                .disabled(tab.isRunning)
            ToolbarButton("Stop the running query (⌘.)", icon: "stop.circle.fill", tint: .red) { tab.stop() }
                .disabled(!tab.isRunning)
            separator
            rowLimitPicker
            separator
            ToolbarButton("Beautify SQL (⌘B)", icon: "wand.and.stars") { beautify() }
            ToolbarButton("Find (⌘F)", icon: "magnifyingglass") { tab.selectedQuery?.editor?.showFindBar() }
            if let document = tab.selectedQuery {
                ToolbarToggle("Show invisible characters", icon: "paragraphsign", isOn: Bindable(document).showsInvisibles)
                ToolbarToggle("Wrap long lines", icon: "arrow.turn.down.left", isOn: Bindable(document).wrapsLines)
            }
            Spacer()
            if tab.isRunning {
                ProgressView().controlSize(.small).padding(.trailing, 6)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var separator: some View {
        Divider().frame(height: 16).padding(.horizontal, 4)
    }

    private var rowLimitPicker: some View {
        Picker("Row limit", selection: rowLimitBinding) {
            ForEach(Self.rowLimits, id: \.self) { limit in
                Text(limit.map { "Limit to \($0) rows" } ?? "Don't Limit").tag(limit)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .help("Adds LIMIT to SELECT statements that don't have one")
    }

    private var rowLimitBinding: Binding<Int?> {
        Binding(
            get: { tab.rowLimit },
            set: { limit in
                tab.rowLimit = limit
                connections.setRowLimit(limit, for: tab.profile.id)
            }
        )
    }

    private func beautify() {
        guard let document = tab.selectedQuery, let editor = document.editor else { return }
        editor.replaceAll(with: SQL.beautify(document.text))
    }
}

/// "Query 1  Query 2  +" above the toolbar.
private struct QueryTabBar: View {
    let tab: ConnectionTab

    var body: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(tab.queries) { document in
                        QueryTabItem(
                            title: document.title,
                            isInfo: document.tableInfo != nil,
                            isSelected: tab.selectedQueryID == document.id,
                            canClose: tab.queries.count > 1,
                            select: { tab.selectedQueryID = document.id },
                            close: { tab.closeQuery(document) }
                        )
                    }
                }
            }
            .scrollIndicators(.never)
            Button("New Query Tab", systemImage: "plus") { tab.newQuery() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("New query tab (⌘T)")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .frame(height: 30)
    }
}

private struct QueryTabItem: View {
    let title: String
    /// Table info tabs get an ⓘ instead of the ⚡.
    let isInfo: Bool
    let isSelected: Bool
    let canClose: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isInfo ? "info.circle.fill" : "bolt.fill")
                .font(.caption2)
                .foregroundStyle(isInfo ? .blue : .yellow)
            Text(title)
                .lineLimit(1)
            if canClose {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(isHovering || isSelected ? 1 : 0)
                .help("Close query tab (⌘W)")
            }
        }
        .font(.callout)
        .padding(.leading, 8)
        .padding(.trailing, canClose ? 4 : 8)
        .frame(height: 22)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(0.1))
            } else if isHovering {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(0.05))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
    }
}

private struct ToolbarButton: View {
    let help: String
    let icon: String
    var tint: Color?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    init(_ help: String, icon: String, tint: Color? = nil, action: @escaping () -> Void) {
        self.help = help
        self.icon = icon
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                // A fixed tint doesn't dim by itself, so disabled buttons go grey explicitly.
                .foregroundStyle(isEnabled ? (tint ?? .primary) : Color.secondary.opacity(0.5))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

private struct ToolbarToggle: View {
    let help: String
    let icon: String
    @Binding var isOn: Bool

    init(_ help: String, icon: String, isOn: Binding<Bool>) {
        self.help = help
        self.icon = icon
        self._isOn = isOn
    }

    var body: some View {
        Button { isOn.toggle() } label: {
            Image(systemName: icon)
                .frame(width: 24, height: 22)
                .background(isOn ? Color.accentColor.opacity(0.25) : .clear, in: .rect(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// Open / save `.sql` files for query tabs.
enum QueryFiles {
    private static let sqlType = UTType(filenameExtension: "sql") ?? .plainText

    static func open(into tab: ConnectionTab) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [sqlType, .plainText]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let document = tab.newQuery(text: text, title: url.lastPathComponent)
            document.fileURL = url
        }
    }

    static func save(_ document: QueryDocument?, saveAs: Bool = false) {
        guard let document, document.tableInfo == nil else { return }
        var url = document.fileURL
        if url == nil || saveAs {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [sqlType]
            panel.nameFieldStringValue = document.fileURL?.lastPathComponent ?? "\(document.title).sql"
            guard panel.runModal() == .OK else { return }
            url = panel.url
        }
        guard let url else { return }
        do {
            try document.text.write(to: url, atomically: true, encoding: .utf8)
            document.fileURL = url
            document.title = url.lastPathComponent
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
