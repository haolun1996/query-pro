import SwiftUI

struct GroupRename: Identifiable {
    enum Kind {
        /// Rename an existing group.
        case rename(String)
        /// Create a group by moving this connection into it.
        case newGroup(UUID)
    }

    let id = UUID()
    let kind: Kind
}

struct RenameGroupSheet: View {
    @Environment(ConnectionsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let rename: GroupRename
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNewGroup ? "New Group" : "Rename Group")
                .font(.headline)
            TextField("Group name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNewGroup ? "Create" : "Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear {
            if case .rename(let old) = rename.kind { name = old }
        }
    }

    private var isNewGroup: Bool {
        if case .newGroup = rename.kind { return true }
        return false
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        switch rename.kind {
        case .rename(let old): model.renameGroup(old, to: trimmed)
        case .newGroup(let id): model.move(id, toGroup: trimmed)
        }
        dismiss()
    }
}
