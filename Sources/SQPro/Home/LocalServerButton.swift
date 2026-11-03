import SwiftUI
import SQCore

/// "● MySQL Running  Stop" in the home header, like Workbench's Startup / Shutdown page.
/// Hidden when Oracle's MySQL isn't installed on this Mac.
struct LocalServerButton: View {
    @Environment(LocalServerController.self) private var server
    @State private var confirmingStop = false

    var body: some View {
        Group {
            if server.status != .notInstalled {
                HStack(spacing: 8) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .foregroundStyle(.secondary)
                    if server.isBusy || server.status == .starting {
                        ProgressView().controlSize(.small)
                    } else if server.status == .running {
                        Button("Stop") { confirmingStop = true }
                    } else {
                        Button("Start") { Task { await server.start() } }
                    }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
                .help("The MySQL server on this Mac (127.0.0.1:3306). Starting or stopping it asks for an administrator password.")
            }
        }
        // Picks up starts and stops made elsewhere (Terminal, the MySQL preference pane).
        .task {
            while !Task.isCancelled {
                await server.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .confirmationDialog("Stop the local MySQL server?", isPresented: $confirmingStop) {
            Button("Stop Server", role: .destructive) { Task { await server.stop() } }
        } message: {
            Text("Open connections to localhost will be closed, and running queries cancelled.")
        }
        .alert(
            "MySQL Server",
            isPresented: Binding(get: { server.lastError != nil }, set: { if !$0 { server.lastError = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(server.lastError ?? "")
        }
    }

    private var statusText: String {
        // While busy, `status` is still the one from before the change.
        if server.isBusy { return server.status == .running ? "MySQL Stopping" : "MySQL Starting" }
        switch server.status {
        case .running: return "MySQL Running"
        case .starting: return "MySQL Starting"
        case .stopped, .notInstalled: return "MySQL Stopped"
        }
    }

    private var dotColor: Color {
        switch server.status {
        case .running: .green
        case .starting: .yellow
        case .stopped, .notInstalled: .secondary
        }
    }
}
