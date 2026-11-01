import SwiftUI
import SQCore

/// The content of one connection tab: schema tree on the left, query editor on the right.
struct ConnectionTabView: View {
    @Bindable var tab: ConnectionTab

    @State private var typedPassword = ""
    @State private var rememberPassword = true

    var body: some View {
        Group {
            switch tab.state {
            case .connected:
                SidebarSplit {
                    SchemaSidebar(tab: tab)
                } detail: {
                    QueryArea(tab: tab)
                }
            case .connecting:
                ProgressView("Connecting to \(tab.profile.address)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Can't connect", systemImage: "bolt.horizontal.circle")
                } description: {
                    Text(message).textSelection(.enabled)
                } actions: {
                    Button("Try Again") { Task { await tab.connect() } }
                }
            }
        }
        .sheet(isPresented: $tab.needsPassword) { passwordSheet }
        .sheet(item: $tab.importJob) { job in
            CSVImportSheet(tab: tab, job: job)
                // Closing mid-import would hide the progress; Stop first.
                .interactiveDismissDisabled(isImporting(job))
        }
    }

    private func isImporting(_ job: CSVImportJob) -> Bool {
        if case .running = job.phase { return true }
        return false
    }

    private var passwordSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Password for \(tab.profile.user)@\(tab.profile.address)")
                .font(.headline)
            SecureField("Password", text: $typedPassword)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submitPassword)
            Toggle("Save password in Keychain", isOn: $rememberPassword)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { tab.needsPassword = false }
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: submitPassword)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func submitPassword() {
        let password = typedPassword
        let remember = rememberPassword
        let profileID = tab.profile.id
        typedPassword = ""
        tab.needsPassword = false
        Task {
            if remember { await Keychain.setPassword(password, for: profileID) }
            await tab.connect(password: password)
        }
    }
}
