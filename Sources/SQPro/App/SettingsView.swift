import AppKit
import SwiftUI
import SQCore

/// App settings (SQ Pro › Settings…, ⌘,).
struct SettingsView: View {
    @AppStorage(SettingsKey.showsDDL) private var showsDDL = true
    @Environment(MCPController.self) private var mcp

    var body: some View {
        @Bindable var mcp = mcp
        Form {
            Section("Table Info") {
                Toggle("Show DDL section", isOn: $showsDDL)
                Text("The CREATE TABLE statement, shown as the last section when you open a table's info.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Enable MCP server", isOn: $mcp.isEnabled)
                LabeledContent("Status") { status }
                TextField("Port", value: $mcp.port, format: .number.grouping(.never))
            } header: {
                Text("MCP Server")
            } footer: {
                Text("""
                    Lets AI clients like Claude Code use your connections. Only this Mac can reach it. Set up each \
                    connection from the MCP button in its tab.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize()
    }

    @ViewBuilder
    private var status: some View {
        switch mcp.status {
        case .stopped:
            Label("Off", systemImage: "circle").foregroundStyle(.secondary)
        case .running(let port):
            Label("Running on port \(port)", systemImage: "circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}

/// Copies `claude mcp add …` for one connection.
struct CopyClaudeCommandButton: View {
    let profile: ConnectionProfile
    var compact = false
    @Environment(MCPController.self) private var mcp
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : (compact ? "Copy Command" : "Copy Claude Code Command"),
               systemImage: copied ? "checkmark" : "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(mcp.claudeCodeCommand(for: profile), forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        }
        .help("claude mcp add … for \(profile.name). Run it in the project folder that should use this connection.")
    }
}

enum SettingsKey {
    static let showsDDL = "showsDDL"
    static let mcpEnabled = "mcpEnabled"
    static let mcpPort = "mcpPort"
    static let mcpTokens = "mcpTokens"
}
