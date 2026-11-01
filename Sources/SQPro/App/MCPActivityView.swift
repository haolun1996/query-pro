import SwiftUI
import SQMCP

/// The AI Activity window: every MCP tool call, newest first, filterable by connection.
struct MCPActivityView: View {
    static let windowID = "mcp-activity"

    @Environment(MCPController.self) private var mcp
    @Environment(ConnectionsModel.self) private var connections

    private var entries: [MCPActivity] { mcp.activity(for: mcp.activityFilter) }

    var body: some View {
        @Bindable var mcp = mcp
        VStack(spacing: 0) {
            HStack {
                Picker("Connection", selection: $mcp.activityFilter) {
                    Text("All connections").tag(UUID?.none)
                    Divider()
                    ForEach(connections.profiles.filter { $0.mcpAccess != .hidden }) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                .fixedSize()
                Spacer()
            }
            .padding(8)
            Divider()
            MCPActivityTable(entries: entries, showsConnection: mcp.activityFilter == nil)
            Divider()
            HStack {
                Text("\(entries.count) call(s)").foregroundStyle(.secondary)
                Spacer()
                Button("Clear", action: mcp.clearActivity).disabled(mcp.activity.isEmpty)
            }
            .padding(8)
        }
        .frame(minWidth: 760, minHeight: 300)
    }
}

/// The table of tool calls, shared by the window and each connection tab's AI Activity panel.
struct MCPActivityTable: View {
    let entries: [MCPActivity]
    var showsConnection = true

    private static let timeFormat = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)

    var body: some View {
        Table(entries) {
            TableColumn("") { entry in Self.icon(entry.outcome) }
                .width(18)
            TableColumn("Time") { Text($0.time, format: Self.timeFormat).monospacedDigit() }
                .width(min: 60, ideal: 70, max: 90)
            TableColumn("Tool") { Text($0.tool) }
                .width(min: 90, ideal: 110, max: 140)
            if showsConnection {
                TableColumn("Connection") { Text($0.connection ?? "") }
                    .width(min: 80, ideal: 120)
            }
            TableColumn("SQL") { entry in
                Text(entry.sql ?? "")
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .help(entry.sql ?? "")
            }
            .width(min: 160, ideal: 360)
            TableColumn("Result") { entry in
                Text(Self.message(entry.outcome))
                    .lineLimit(1)
                    .foregroundStyle(Self.color(entry.outcome))
                    .help(Self.message(entry.outcome))
            }
            .width(min: 120, ideal: 260)
            TableColumn("Duration") { entry in
                Text(entry.duration.map { $0.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)) } ?? "")
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 70, max: 100)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .font(.callout)
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("No AI activity yet", systemImage: "sparkles",
                                       description: Text("Tool calls from Claude Code and other MCP clients appear here."))
            }
        }
    }

    @ViewBuilder
    static func icon(_ outcome: MCPActivity.Outcome) -> some View {
        switch outcome {
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .blocked: Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    static func message(_ outcome: MCPActivity.Outcome) -> String {
        switch outcome {
        case .success(let text), .blocked(let text), .failed(let text): text
        }
    }

    static func color(_ outcome: MCPActivity.Outcome) -> Color {
        switch outcome {
        case .success: .primary
        case .blocked: .orange
        case .failed: .red
        }
    }
}
