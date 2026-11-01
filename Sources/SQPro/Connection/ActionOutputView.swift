import SwiftUI

/// The bottom of a connection tab: Action Output (this session), History (every query run on this connection)
/// or AI Activity (what Claude ran here).
struct BottomPanelView: View {
    @Bindable var tab: ConnectionTab
    @Environment(MCPController.self) private var mcp
    @State private var historySearch = ""
    @State private var confirmClearHistory = false

    var body: some View {
        let aiEntries = mcp.activity(for: tab.profile.id)
        VStack(spacing: 0) {
            HStack {
                Picker("Panel", selection: $tab.bottomPanel) {
                    Text("Action Output").tag(ConnectionTab.BottomPanel.output)
                    Text("History").tag(ConnectionTab.BottomPanel.history)
                    Text(aiEntries.isEmpty ? "AI Activity" : "AI Activity (\(aiEntries.count))").tag(ConnectionTab.BottomPanel.aiActivity)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                Spacer()
                if tab.bottomPanel == .output {
                    Button("Clear", systemImage: "trash") { tab.clearLog() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .disabled(tab.log.isEmpty)
                        .help("Clear the output")
                } else if tab.bottomPanel == .history {
                    HistorySearchField(text: $historySearch)
                    Button("Clear History", systemImage: "trash") { confirmClearHistory = true }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .disabled(tab.history.isEmpty)
                        .help("Delete this connection's whole history")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

            switch tab.bottomPanel {
            case .output: ActionOutputView(tab: tab)
            case .history: HistoryView(tab: tab, search: historySearch)
            case .aiActivity: MCPActivityTable(entries: aiEntries, showsConnection: false)
            }
        }
        .confirmationDialog("Delete the query history of \(tab.profile.name)?", isPresented: $confirmClearHistory) {
            Button("Delete History", role: .destructive) { tab.clearHistory() }
        } message: {
            Text("Saved queries are kept.")
        }
    }
}

/// The Action Output table: one row per statement run, like Workbench's.
struct ActionOutputView: View {
    let tab: ConnectionTab

    private static let timeFormat = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)

    var body: some View {
        VStack(spacing: 0) {
            Table(tab.log.reversed()) {
                TableColumn("") { entry in
                    statusIcon(entry.status)
                }
                .width(18)
                TableColumn("#") { entry in
                    Text("\(entry.index)").monospacedDigit()
                }
                .width(min: 24, ideal: 30, max: 50)
                TableColumn("Time") { entry in
                    Text(entry.time, format: Self.timeFormat).monospacedDigit()
                }
                .width(min: 60, ideal: 70, max: 90)
                TableColumn("Action") { entry in
                    Text(entry.action).lineLimit(1).help(entry.action)
                }
                .width(min: 120, ideal: 420)
                TableColumn("Response") { entry in
                    Text(entry.response)
                        .lineLimit(1)
                        .foregroundStyle(entry.status == .error ? .red : .primary)
                        .help(entry.response)
                }
                .width(min: 120, ideal: 320)
                TableColumn("Duration") { entry in
                    Text(entry.duration.map(Self.format) ?? "").monospacedDigit()
                }
                .width(min: 60, ideal: 90, max: 140)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .font(.callout)
            .contextMenu(forSelectionType: ActionLogEntry.ID.self) { ids in
                Button("Copy Action") { copy(ids) { $0.action } }
                Button("Copy Response") { copy(ids) { $0.response } }
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: ActionLogEntry.Status) -> some View {
        switch status {
        case .running:
            ProgressView().controlSize(.mini)
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .error:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private static func format(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.3f sec", seconds)
    }

    private func copy(_ ids: Set<ActionLogEntry.ID>, _ field: (ActionLogEntry) -> String) {
        let text = tab.log.filter { ids.contains($0.id) }.map(field).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
