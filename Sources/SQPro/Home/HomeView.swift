import AppKit
import SwiftUI
import SQCore

/// The start screen: connection cards and group folders, like Workbench's home tab.
struct HomeView: View {
    @Environment(ConnectionsModel.self) private var model
    @Environment(Workspace.self) private var workspace
    @Environment(MCPController.self) private var mcp

    @State private var editor: EditorRequest?
    @State private var renaming: GroupRename?
    @State private var deleting: ConnectionProfile?

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let error = model.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                GlassEffectContainer(spacing: 14) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        cards
                    }
                }
                if isEmpty { emptyState }
            }
            .padding(24)
        }
        .background { HomeBackground() }
        .sheet(item: $editor) { request in
            ConnectionEditorView(profile: request.profile, isNew: request.isNew)
        }
        .sheet(item: $renaming) { rename in
            RenameGroupSheet(rename: rename)
        }
        .confirmationDialog(
            "Delete \"\(deleting?.name ?? "")\"?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { profile in
            Button("Delete", role: .destructive) { model.delete(profile) }
        } message: { _ in
            Text("The saved password is removed from the Keychain too.")
        }
        .onChange(of: model.groups) {
            if let currentGroup, !model.groups.contains(currentGroup) { self.currentGroup = nil }
        }
    }

    private var currentGroup: String? {
        get { workspace.homeGroup }
        nonmutating set { workspace.homeGroup = newValue }
    }

    private var filter: String { workspace.homeFilter }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.title.bold())
            Button("New Connection", systemImage: "plus.circle", action: newConnection)
                .labelStyle(.iconOnly)
                .font(.title2)
                .buttonStyle(.borderless)
                .help("New connection")
            Spacer()
            LocalServerButton()
            FilterField(text: Bindable(workspace).homeFilter)
        }
    }

    private var title: String {
        if !filter.isEmpty { return "MySQL Connections / Search" }
        if let currentGroup { return "MySQL Connections / \(currentGroup)" }
        return "MySQL Connections"
    }

    // MARK: Cards

    @ViewBuilder
    private var cards: some View {
        if !filter.isEmpty {
            ForEach(model.search(filter)) { connectionCard($0) }
        } else if let group = currentGroup {
            BackCard { withAnimation(.snappy) { currentGroup = nil } }
                .dropDestination(for: String.self) { ids, _ in _ = moveDropped(ids, to: nil) }
            ForEach(model.profiles(inGroup: group)) { connectionCard($0) }
        } else {
            ForEach(model.profiles(inGroup: nil)) { connectionCard($0) }
            ForEach(model.groups, id: \.self) { groupCard($0) }
        }
    }

    private func connectionCard(_ profile: ConnectionProfile) -> some View {
        ConnectionCard(profile: profile, showsGroup: !filter.isEmpty) { open(profile) }
            .draggable(profile.id.uuidString)
            .contextMenu {
                Button("Open Connection") { open(profile) }
                Divider()
                Button("Edit Connection…") { editor = EditorRequest(profile: profile, isNew: false) }
                Button("Duplicate") { model.duplicate(profile) }
                if profile.mcpAccess != .hidden {
                    Button("Copy Claude Code Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(mcp.claudeCodeCommand(for: profile), forType: .string)
                    }
                }
                Menu("Move to Group") {
                    ForEach(model.groups.filter { $0 != profile.groupName }, id: \.self) { group in
                        Button(group) { model.move(profile.id, toGroup: group) }
                    }
                    Divider()
                    Button("New Group…") { renaming = GroupRename(kind: .newGroup(profile.id)) }
                    if profile.groupName != nil {
                        Button("Remove from Group") { model.move(profile.id, toGroup: nil) }
                    }
                }
                Divider()
                Button("Delete…", role: .destructive) { deleting = profile }
            }
    }

    private func groupCard(_ group: String) -> some View {
        GroupCard(
            name: group,
            count: model.profiles(inGroup: group).count,
            action: { withAnimation(.snappy) { currentGroup = group } },
            onDrop: { moveDropped($0, to: group) }
        )
        .contextMenu {
            Button("Open Group") { currentGroup = group }
            Button("Rename Group…") { renaming = GroupRename(kind: .rename(group)) }
            Divider()
            Button("Ungroup Connections") { model.ungroup(group) }
        }
    }

    // MARK: Empty state

    private var isEmpty: Bool {
        if !filter.isEmpty { return model.search(filter).isEmpty }
        return model.profiles.isEmpty
    }

    @ViewBuilder
    private var emptyState: some View {
        if filter.isEmpty {
            ContentUnavailableView {
                Label("No connections yet", systemImage: "cylinder.split.1x2")
            } actions: {
                Button("New Connection", action: newConnection)
                    .buttonStyle(.glassProminent)
            }
        } else {
            ContentUnavailableView.search(text: filter)
        }
    }

    // MARK: Actions

    private func newConnection() {
        var profile = ConnectionProfile()
        profile.group = currentGroup
        editor = EditorRequest(profile: profile, isNew: true)
    }

    private func open(_ profile: ConnectionProfile) {
        workspace.open(profile)
    }

    private func moveDropped(_ ids: [String], to group: String?) -> Bool {
        let uuids = ids.compactMap(UUID.init(uuidString:))
        for id in uuids { model.move(id, toGroup: group) }
        return !uuids.isEmpty
    }
}

struct EditorRequest: Identifiable {
    var id: UUID { profile.id }
    var profile: ConnectionProfile
    var isNew: Bool
}

/// The "Filter connections" box at the top right, like Workbench's.
private struct FilterField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter connections", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 240)
        .glassEffect(.regular, in: .capsule)
    }
}

/// A soft colour wash behind the cards so the glass has something to refract.
private struct HomeBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [.blue.opacity(0.22), .clear], center: .topLeading, startRadius: 0, endRadius: 700)
            RadialGradient(colors: [.purple.opacity(0.14), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 600)
        }
        .ignoresSafeArea()
    }
}
