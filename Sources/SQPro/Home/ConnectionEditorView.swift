import SwiftUI
import SQCore

/// Add or edit a saved connection. The password goes to the Keychain, everything else to connections.json.
struct ConnectionEditorView: View {
    @Environment(ConnectionsModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var profile: ConnectionProfile
    @State private var password = ""
    @State private var passwordChanged = false
    @State private var test = TestState.idle
    let isNew: Bool

    init(profile: ConnectionProfile, isNew: Bool) {
        _profile = State(initialValue: profile)
        self.isNew = isNew
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $profile.name, prompt: Text("e.g. Local My Sapu"))
                    groupField
                    Picker("Color", selection: $profile.color) {
                        ForEach(ConnectionColor.allCases, id: \.self) { color in
                            Label { Text(color.title) } icon: { color.swatch }
                                .tag(color)
                        }
                    }
                }

                Section("Server") {
                    TextField("Host", text: $profile.host)
                    TextField("Port", value: $profile.port, format: .number.grouping(.never))
                    TextField("Username", text: $profile.user)
                    SecureField("Password", text: $password, prompt: Text(isNew ? "Optional" : "Unchanged"))
                        .onChange(of: password) { passwordChanged = true }
                    TextField("Default Schema", text: $profile.defaultSchema, prompt: Text("Optional"))
                }
            }
            .formStyle(.grouped)

            if case .failure(let message) = test {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
            }
            footer
        }
        .frame(width: 480)
        .task { await loadPassword() }
    }

    private var groupField: some View {
        HStack {
            TextField("Group", text: groupBinding, prompt: Text("None"))
            Menu {
                Button("None") { profile.group = nil }
                if !model.groups.isEmpty { Divider() }
                ForEach(model.groups, id: \.self) { group in
                    Button(group) { profile.group = group }
                }
            } label: {
                Image(systemName: "folder")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Pick an existing group")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Test Connection", action: runTest)
                .disabled(test == .testing || profile.host.isEmpty)
            testStatus
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isNew ? "Add" : "Save", action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(profile.host.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(16)
    }

    @ViewBuilder
    private var testStatus: some View {
        switch test {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .lineLimit(1)
        case .failure(let message):
            Label("Failed", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .help(message)
        }
    }

    private var groupBinding: Binding<String> {
        Binding(get: { profile.group ?? "" }, set: { profile.group = $0.isEmpty ? nil : $0 })
    }

    private func loadPassword() async {
        guard !isNew else { return }
        password = await Keychain.password(for: profile.id) ?? ""
        passwordChanged = false
    }

    private func runTest() {
        test = .testing
        let profile = cleaned
        let password = password
        Task {
            let session = MySQLSession(profile: profile, password: password)
            do {
                try await session.connect()
                let version = try await session.execute("SELECT VERSION()").rows.first?.first ?? nil
                await session.close()
                test = .success("Connected · MySQL \(version ?? "")")
            } catch {
                await session.close()
                test = .failure(ErrorText.message(for: error))
            }
        }
    }

    private func save() {
        let profile = cleaned
        let password = password
        let savePassword = isNew || passwordChanged
        Task {
            if savePassword, !(await Keychain.setPassword(password, for: profile.id)) {
                test = .failure("Couldn't save the password to the Keychain.")
                return
            }
            model.save(profile)
            dismiss()
        }
    }

    private var cleaned: ConnectionProfile {
        var profile = profile
        profile.name = profile.name.trimmingCharacters(in: .whitespaces)
        profile.host = profile.host.trimmingCharacters(in: .whitespaces)
        profile.user = profile.user.trimmingCharacters(in: .whitespaces)
        profile.group = profile.groupName
        if profile.name.isEmpty { profile.name = profile.address }
        return profile
    }
}

private enum TestState: Equatable {
    case idle
    case testing
    case success(String)
    case failure(String)
}
