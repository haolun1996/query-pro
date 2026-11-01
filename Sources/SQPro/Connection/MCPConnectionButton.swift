import SwiftUI
import SQCore
import SQMCP

/// "● MCP" at the right of a connection's query tab row. Green when Claude can use this connection,
/// grey when the server is off, struck through when the connection is hidden from AI.
struct MCPConnectionButton: View {
    let tab: ConnectionTab
    @Environment(MCPController.self) private var mcp
    @Environment(ConnectionsModel.self) private var connections
    @State private var isOpen = false

    /// The saved profile, so access changes made here or in Edit Connection show up right away.
    private var profile: ConnectionProfile {
        connections.profile(id: tab.profile.id) ?? tab.profile
    }

    private var isRunning: Bool {
        if case .running = mcp.status { return true }
        return false
    }

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(profile.mcpAccess != .hidden && isRunning ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text("MCP")
                    .strikethrough(profile.mcpAccess == .hidden)
                let count = mcp.activity(for: profile.id).count
                if count > 0 {
                    Text("\(count)").foregroundStyle(.secondary)
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            // Glass behind the label (like the tab strip's tabs), so the text keeps its normal colour.
            .background { Capsule().fill(.clear).glassEffect(.regular, in: .capsule) }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help("Claude Code access to this connection")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            MCPConnectionPopover(tab: tab, profile: profile) { isOpen = false }
        }
    }
}

private struct MCPConnectionPopover: View {
    let tab: ConnectionTab
    let profile: ConnectionProfile
    let close: () -> Void
    @Environment(MCPController.self) private var mcp
    @Environment(ConnectionsModel.self) private var connections
    @State private var confirmNewToken = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Code · \(profile.name)")
                .font(.headline)

            serverRow

            Picker("AI access", selection: accessBinding) {
                Text("Hidden").tag(MCPAccess.hidden)
                Text("Read only").tag(MCPAccess.readOnly)
                Text("Read & write").tag(MCPAccess.readWrite)
            }
            .pickerStyle(.segmented)

            if profile.mcpAccess != .hidden {
                Text(loginText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        CopyClaudeCommandButton(profile: profile)
                        Button("New Token") { confirmNewToken = true }
                            .help("Stops the current token; projects using it need the new command")
                    }
                    Text("Run the command inside the project folder that should use this connection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()
                recentActivity
            } else {
                Text("Claude can't see this connection. Choose Read only or Read & write to set it up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 380)
        .confirmationDialog("Create a new token for \(profile.name)?", isPresented: $confirmNewToken) {
            Button("New Token", role: .destructive) { mcp.regenerateToken(for: profile) }
        } message: {
            Text("Claude Code projects using the old token lose access until you run the new command there.")
        }
    }

    @ViewBuilder
    private var serverRow: some View {
        HStack {
            switch mcp.status {
            case .running(let port):
                Label("Server running on port \(port)", systemImage: "circle.fill")
                    .foregroundStyle(.green)
            case .stopped:
                Label("Server is off", systemImage: "circle")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Turn On") { mcp.isEnabled = true }
                    .controlSize(.small)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
    }

    private var recentActivity: some View {
        let entries = mcp.activity(for: profile.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent AI activity").font(.callout.bold())
                Spacer()
                if !entries.isEmpty {
                    Button("Show All") {
                        tab.bottomPanel = .aiActivity
                        close()
                    }
                    .buttonStyle(.link)
                }
            }
            if entries.isEmpty {
                Text("Nothing yet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(entries.prefix(5)) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    MCPActivityTable.icon(entry.outcome)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.sql ?? entry.tool)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        Text("\(entry.tool) · \(MCPActivityTable.message(entry.outcome))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(entry.time, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var loginText: String {
        let user = profile.effectiveMCPUser
        let access = profile.mcpAccess == .readWrite
            ? (profile.color.isProduction ? "can change data (each change asks you first)" : "can change data")
            : "can only read"
        let login = profile.usesSeparateMCPUser ? "its own MySQL user \(user)" : "\(user), the same user as you"
        return "Claude \(access) and logs in as \(login). Set a separate AI user in Edit Connection."
    }

    private var accessBinding: Binding<MCPAccess> {
        Binding(
            get: { profile.mcpAccess },
            set: { access in
                var updated = profile
                updated.mcpAccess = access
                connections.save(updated)
            }
        )
    }
}
