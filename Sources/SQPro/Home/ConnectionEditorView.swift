import AppKit
import SwiftUI
import SQCore

/// Add or edit a saved connection. The password goes to the Keychain, everything else to connections.json.
struct ConnectionEditorView: View {
    @Environment(ConnectionsModel.self) private var model
    @Environment(MCPController.self) private var mcp
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var confirmNewToken = false

    @State private var profile: ConnectionProfile
    @State private var password = ""
    @State private var passwordChanged = false
    @State private var usesAIUser: Bool
    @State private var aiPassword = ""
    @State private var aiPasswordChanged = false
    @State private var test = TestState.idle
    @State private var copiedExample = false
    let isNew: Bool

    init(profile: ConnectionProfile, isNew: Bool) {
        _profile = State(initialValue: profile)
        _usesAIUser = State(initialValue: profile.usesSeparateMCPUser)
        self.isNew = isNew
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Type", selection: Binding(get: { profile.kind }, set: { profile.change(kind: $0) })) {
                        ForEach(DatabaseKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField("Name", text: $profile.name, prompt: Text(profile.kind == .redis ? "e.g. Cache (production)" : "e.g. Local MySQL"))
                    groupField
                    Picker("Color", selection: $profile.color) {
                        ForEach(ConnectionColor.allCases, id: \.self) { color in
                            Label { Text(color.title) } icon: { color.swatch }
                                .tag(color)
                        }
                    }
                }

                Section {
                    TextField("Host", text: $profile.host)
                    TextField("Port", value: $profile.port, format: .number.grouping(.never))
                    TextField("Username", text: $profile.user, prompt: Text(profile.kind == .redis ? "default (password only)" : ""))
                    SecureField("Password", text: $password, prompt: Text(isNew ? "Optional" : "Unchanged"))
                        .onChange(of: password) { passwordChanged = true }
                    switch profile.kind {
                    case .mysql:
                        TextField("Default Schema", text: $profile.defaultSchema, prompt: Text("Optional"))
                    case .redis:
                        TextField("Database", value: $profile.redisDatabase, format: .number.grouping(.never))
                        Toggle("Use TLS", isOn: Binding(
                            get: { profile.sslMode == .required },
                            set: { profile.sslMode = $0 ? .required : .disabled }
                        ))
                    }
                } header: {
                    Text("Server")
                } footer: {
                    if profile.kind == .redis {
                        Text("Cloud services (ElastiCache with in-transit encryption, Redis Cloud, Upstash, Azure) need TLS and usually a username. Certificates aren't checked, so self-signed and private-CA servers work.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Picker("AI access (MCP)", selection: $profile.mcpAccess) {
                        Text("Hidden").tag(MCPAccess.hidden)
                        Text("Read only").tag(MCPAccess.readOnly)
                        Text("Read & write").tag(MCPAccess.readWrite)
                    }
                    if profile.mcpAccess != .hidden {
                        Toggle("Use a separate \(profile.kind.title) user for AI", isOn: $usesAIUser)
                        if usesAIUser {
                            TextField("AI username", text: $profile.mcpUser, prompt: Text("e.g. ai_reader"))
                            SecureField("AI password", text: $aiPassword, prompt: Text(profile.usesSeparateMCPUser && !isNew ? "Unchanged" : "Optional"))
                                .onChange(of: aiPassword) { aiPasswordChanged = true }
                            HStack {
                                Button("Test AI Login") { runTest(asAI: true) }
                                    .disabled(test == .testing || !cleaned.usesSeparateMCPUser)
                                Spacer()
                                Button(
                                    copiedExample ? "Copied" : profile.kind == .redis ? "Copy ACL for a Read-Only User" : "Copy SQL for a Read-Only User",
                                    systemImage: copiedExample ? "checkmark" : "doc.on.doc"
                                ) {
                                    copyExampleSQL()
                                }
                                .help(profile.kind == .redis ? "An ACL SETUSER command to run as an admin user" : "CREATE USER and GRANT SELECT statements to run as root")
                            }
                            .controlSize(.small)
                        }
                        HStack {
                            CopyClaudeCommandButton(profile: cleaned)
                            Spacer()
                            Button("New Token") { confirmNewToken = true }
                                .help("Stops the current token; projects using it need the new command")
                            Button("Activity…") {
                                mcp.activityFilter = profile.id
                                openWindow(id: MCPActivityView.windowID)
                            }
                        }
                        .controlSize(.small)
                    }
                } footer: {
                    Text(accessHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        .confirmationDialog("Create a new token for \(cleaned.name)?", isPresented: $confirmNewToken) {
            Button("New Token", role: .destructive) { mcp.regenerateToken(for: profile) }
        } message: {
            Text("Claude Code projects using the old token lose access until you run the new command there.")
        }
    }

    private var accessHelp: String {
        let level = switch profile.mcpAccess {
        case .hidden: "AI clients can't see this connection."
        case .readOnly where profile.kind == .redis: "AI clients can scan keys, read values and run read-only commands."
        case .readOnly: "AI clients can look at the schema and run SELECT / SHOW queries."
        case .readWrite where profile.color.isProduction: "AI clients can also change data. Each change asks you first, because this is a red (production) connection."
        case .readWrite: "AI clients can also change data and schema."
        }
        guard profile.mcpAccess != .hidden else { return level }
        let login = usesAIUser
            ? " They log in as \(cleaned.effectiveMCPUser), so \(profile.kind.title) only lets them do what that user is allowed."
            : " They log in as \(profile.user.isEmpty ? "the default user" : profile.user), the same user as you."
        return level + login
    }

    /// A read-only MySQL account for AI, limited to the default schema if there is one.
    private func copyExampleSQL() {
        let user = cleaned.usesSeparateMCPUser ? cleaned.effectiveMCPUser : "ai_reader"
        guard profile.kind == .mysql else {
            // Reads only, nothing that blocks or administers the server; INFO for server_info, PING for health checks.
            copy("ACL SETUSER \(user) on >choose-a-strong-password ~* &* +@read -@dangerous +info +ping")
            return
        }
        let host = ["localhost", "127.0.0.1", "::1"].contains(profile.host) ? "localhost" : "%"
        let schema = profile.defaultSchema.isEmpty ? "your_database" : profile.defaultSchema
        let sql = """
            CREATE USER '\(user)'@'\(host)' IDENTIFIED BY 'choose-a-strong-password';
            GRANT SELECT, SHOW VIEW ON `\(schema)`.* TO '\(user)'@'\(host)';
            """
        copy(sql)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedExample = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copiedExample = false
        }
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
            Button("Test Connection") { runTest(asAI: false) }
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
        aiPassword = await Keychain.password(for: profile.id, kind: .mcp) ?? ""
        passwordChanged = false
        aiPasswordChanged = false
    }

    /// `asAI`: log in as the separate AI user, the way MCP will.
    private func runTest(asAI: Bool) {
        test = .testing
        var profile = cleaned
        let password = asAI ? aiPassword : password
        if asAI { profile.user = profile.effectiveMCPUser }
        Task {
            if profile.kind == .redis {
                let session = RedisSession(profile: profile, password: password)
                do {
                    try await session.connect()
                    let info = try await session.call("INFO", "server").string ?? ""
                    await session.close()
                    let version = RedisBrowser.infoField("redis_version", in: info) ?? ""
                    test = .success(asAI ? "AI login works · \(profile.user)" : "Connected · Redis \(version)")
                } catch {
                    await session.close()
                    test = .failure(ErrorText.message(for: error))
                }
                return
            }
            let session = MySQLSession(profile: profile, password: password)
            do {
                try await session.connect()
                let version = try await session.execute("SELECT VERSION()").rows.first?.first ?? nil
                await session.close()
                test = .success(asAI ? "AI login works · \(profile.user)" : "Connected · MySQL \(version ?? "")")
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
        let aiPassword = profile.usesSeparateMCPUser ? aiPassword : nil
        let saveAIPassword = isNew || aiPasswordChanged || !profile.usesSeparateMCPUser
        Task {
            if savePassword, !(await Keychain.setPassword(password, for: profile.id)) {
                test = .failure("Couldn't save the password to the Keychain.")
                return
            }
            // Turning the AI user off also forgets its password.
            if saveAIPassword, !(await Keychain.setPassword(aiPassword, for: profile.id, kind: .mcp)) {
                test = .failure("Couldn't save the AI password to the Keychain.")
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
        profile.mcpUser = usesAIUser ? profile.mcpUser.trimmingCharacters(in: .whitespaces) : ""
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
