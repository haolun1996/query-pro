import AppKit
import SwiftUI
import SQCore

/// The content of one Redis tab: keys on the left, the selected key's value on the right, console underneath.
struct RedisTabView: View {
    @Bindable var tab: RedisTab
    @State private var typedPassword = ""
    @State private var rememberPassword = true

    var body: some View {
        Group {
            switch tab.state {
            case .connected:
                SidebarSplit {
                    RedisKeySidebar(tab: tab)
                } detail: {
                    VerticalSplit(storageKey: "redisConsoleHeight", defaultBottomHeight: 220, showsBottom: tab.showsConsole, minTop: 140) {
                        RedisValueView(tab: tab)
                    } bottom: {
                        RedisBottomPanel(tab: tab)
                    }
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
        .sheet(isPresented: $tab.showsNewKey) { NewRedisKeySheet(tab: tab) }
    }

    private var passwordSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tab.profile.user.isEmpty ? "Password for \(tab.profile.address)" : "Password for \(tab.profile.user)@\(tab.profile.address)")
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

// MARK: Sidebar

/// KEYS: database picker, filter, and the keys grouped into folders by `:`.
struct RedisKeySidebar: View {
    @Bindable var tab: RedisTab
    @State private var filterText = ""

    static let types = ["string", "hash", "list", "set", "zset", "stream"]

    var body: some View {
        VStack(spacing: 0) {
            header
            List(selection: $tab.selectedNodeID) {
                OutlineGroup(tab.tree, children: \.children) { node in
                    RedisKeyRow(node: node)
                        .listRowSeparator(.hidden)
                        .contextMenu { menu(for: node) }
                }
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 22)
            .overlay {
                if tab.keys.isEmpty, !tab.isScanning {
                    Text(tab.scanError ?? (tab.filter.isEmpty && tab.typeFilter == nil ? "No keys in db\(tab.database)" : "No matching keys"))
                        .font(.callout)
                        .foregroundStyle(tab.scanError == nil ? Color.secondary : Color.red)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            .onChange(of: tab.selectedNodeID) { Task { await tab.selectionChanged() } }
            Divider()
            footer
        }
        .background(.regularMaterial, ignoresSafeAreaEdges: [])
        .onAppear { filterText = tab.filter }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("KEYS")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                MCPConnectionButton(tabProfile: tab.profile) {
                    tab.showsConsole = true
                    tab.bottomPanel = .aiActivity
                }
                Spacer()
                Button("New Key", systemImage: "plus") { tab.showsNewKey = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("New key")
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task {
                        await tab.refreshKeyCounts()
                        await tab.reload()
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Scan again")
            }
            .controlSize(.small)
            HStack(spacing: 6) {
                Picker("Database", selection: Binding(get: { tab.database }, set: { number in Task { await tab.select(database: number) } })) {
                    ForEach(0..<tab.databaseCount, id: \.self) { number in
                        Text(tab.keyCounts[number].map { "db\(number) · \($0)" } ?? "db\(number)").tag(number)
                    }
                }
                .labelsHidden()
                .help("Database (SELECT)")
                Picker("Type", selection: Binding(get: { tab.typeFilter }, set: { type in
                    tab.typeFilter = type
                    Task { await tab.reload() }
                })) {
                    Text("All types").tag(String?.none)
                    Divider()
                    ForEach(Self.types, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .labelsHidden()
                .help("Only keys of this type (SCAN … TYPE, Redis 6+)")
            }
            .controlSize(.small)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter keys (Return)", text: $filterText)
                    .textFieldStyle(.plain)
                    .onSubmit(applyFilter)
                if !filterText.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") {
                        filterText = ""
                        applyFilter()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 6))
            .help("Text matches anywhere in the name; *, ? and [ ] make it a SCAN pattern. The server does the matching.")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if tab.isScanning {
                ProgressView().controlSize(.mini)
                Text("Scanning…")
            } else {
                Text(tab.keys.count == 1 ? "1 key" : "\(tab.keys.count) keys")
                if tab.hasMore { Text("(more on server)").foregroundStyle(.tertiary) }
            }
            Spacer()
            if tab.hasMore, !tab.isScanning {
                Button("Load More") { Task { await tab.loadMore() } }
                    .buttonStyle(.link)
                    .help("Scan the next \(RedisTab.pageSize) keys")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func applyFilter() {
        tab.filter = filterText
        Task { await tab.reload() }
    }

    @ViewBuilder
    private func menu(for node: RedisKeyNode) -> some View {
        if let key = node.key {
            Button("Copy Name") { copy(key.displayName) }
            Button("Copy as Command") { copy("GET " + RedisCommand.quote(key.name)) }
            Divider()
            Button("Delete Key…", role: .destructive) { Task { await tab.delete(key) } }
        } else {
            Button("Copy Prefix") { copy(String(node.id.dropFirst(2)) + ":") }
            Button("Filter to This Folder") {
                filterText = String(node.id.dropFirst(2)) + ":*"
                applyFilter()
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct RedisKeyRow: View {
    let node: RedisKeyNode

    var body: some View {
        HStack(spacing: 6) {
            if let key = node.key {
                RedisTypeBadge(type: key.type)
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if key.ttl != nil {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Expires in \(RedisBrowser.formatTTL(milliseconds: key.ttl ?? 0))")
                }
            } else {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.blue)
                    .font(.caption)
                Text(node.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(node.keyCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.callout)
        .help(node.key?.displayName ?? "")
    }
}

/// "STR", "HASH" … in the type's colour.
struct RedisTypeBadge: View {
    let type: String

    var body: some View {
        Text(label)
            .font(.system(size: 8.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 34, height: 14)
            .background(color.gradient, in: .rect(cornerRadius: 3))
    }

    private var label: String {
        switch type {
        case "string": "STR"
        case "hash": "HASH"
        case "list": "LIST"
        case "set": "SET"
        case "zset": "ZSET"
        case "stream": "STRM"
        default: String(type.prefix(4)).uppercased()
        }
    }

    private var color: Color {
        switch type {
        case "string": .blue
        case "hash": .green
        case "list": .orange
        case "set": .purple
        case "zset": .pink
        case "stream": .teal
        default: .gray
        }
    }
}

// MARK: Bottom panel

/// Console, or this connection's AI activity.
struct RedisBottomPanel: View {
    @Bindable var tab: RedisTab
    @Environment(MCPController.self) private var mcp

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Panel", selection: $tab.bottomPanel) {
                    Text("Console").tag(RedisTab.BottomPanel.console)
                    Text("AI Activity").tag(RedisTab.BottomPanel.aiActivity)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if tab.bottomPanel == .console {
                    if tab.isRunningCommand {
                        Button("Stop", systemImage: "stop.fill") { Task { await tab.stopConsoleCommand() } }
                            .help("Stop waiting: closes the console's connection and opens a new one")
                    }
                    Button("Clear", systemImage: "trash") { tab.clearConsole() }
                        .labelStyle(.iconOnly)
                        .disabled(tab.console.isEmpty)
                        .help("Clear the console")
                }
                Button("Hide", systemImage: "chevron.down") { tab.showsConsole = false }
                    .labelStyle(.iconOnly)
                    .help("Hide the console")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            switch tab.bottomPanel {
            case .console: RedisConsoleView(tab: tab)
            case .aiActivity: MCPActivityTable(entries: mcp.activity(for: tab.profile.id), showsConnection: false)
            }
        }
    }
}
