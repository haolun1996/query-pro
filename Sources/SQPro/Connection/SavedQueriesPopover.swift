import SwiftUI
import SQCore

/// The bookmark button's popover: saved queries for this connection, and a form to save the current one.
struct SavedQueriesPopover: View {
    @Bindable var tab: ConnectionTab
    @Environment(SavedQueriesModel.self) private var saved
    @State private var search = ""
    @State private var newName = ""
    @State private var forAllConnections = false
    @State private var renaming: SavedQuery?
    @State private var renameText = ""
    @State private var replacing: SavedQuery?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Saved Queries").font(.headline)
                Spacer()
                if !tab.savesNewQuery {
                    Button("Save Current Query", systemImage: "plus") { startSaving() }
                        .disabled(editorSQL.isEmpty)
                        .help("Save the selection, or the whole editor (⌥⌘S)")
                }
            }
            if tab.savesNewQuery {
                saveForm
                Divider()
            }
            if !all.isEmpty {
                searchField
            }
            list
            if let error = saved.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(width: 440)
        .onAppear { if tab.savesNewQuery { startSaving() } }
        .alert("Rename Saved Query", isPresented: isRenaming) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if var query = renaming, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                    query.name = renameText.trimmingCharacters(in: .whitespaces)
                    saved.update(query)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Replace the SQL of \(replacing?.name ?? "")?", isPresented: isReplacing) {
            Button("Replace") {
                if var query = replacing {
                    query.sql = editorSQL
                    saved.update(query)
                }
            }
        } message: {
            Text("It gets the editor's selection, or the whole editor if nothing is selected.")
        }
    }

    // MARK: Saving

    private var saveForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: $newName, prompt: Text("Name"))
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(save)
            Text(editorSQL)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
            HStack {
                Toggle("Show for all connections", isOn: $forAllConnections)
                    .help("Off: only \(tab.profile.name) lists it")
                Spacer()
                Button("Cancel") { tab.savesNewQuery = false }
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || editorSQL.isEmpty)
            }
            .controlSize(.small)
        }
    }

    private func startSaving() {
        tab.savesNewQuery = true
        newName = defaultName
        nameFocused = true
    }

    private func save() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !editorSQL.isEmpty else { return }
        saved.add(name: name, sql: editorSQL, connectionID: forAllConnections ? nil : tab.profile.id)
        tab.savesNewQuery = false
        newName = ""
    }

    /// The selection, or the whole editor.
    private var editorSQL: String {
        guard let document = tab.selectedQuery, document.tableInfo == nil else { return "" }
        let text = document.text as NSString
        let selection = document.selection
        let sql = selection.length > 0 && NSMaxRange(selection) <= text.length ? text.substring(with: selection) : document.text
        return sql.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The file name, or the start of the first statement.
    private var defaultName: String {
        if let url = tab.selectedQuery?.fileURL { return url.deletingPathExtension().lastPathComponent }
        let first = SQL.statements(in: editorSQL).first?.text ?? editorSQL
        let line = first.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > 40 ? String(line.prefix(40)) + "…" : line
    }

    // MARK: List

    private var all: [SavedQuery] {
        saved.queries(for: tab.profile.id)
    }

    private var filtered: [SavedQuery] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(needle) || $0.sql.localizedCaseInsensitiveContains(needle) }
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $search).textFieldStyle(.plain)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 6))
    }

    @ViewBuilder
    private var list: some View {
        if all.isEmpty {
            Text("Nothing saved yet. Write a query, then press Save Current Query.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if filtered.isEmpty {
            Text("No saved query matches “\(search)”.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(filtered) { query in
                        SavedQueryRow(query: query) {
                            open(query)
                        } insert: {
                            insert(query)
                        }
                        .contextMenu { menu(for: query) }
                    }
                }
            }
            .frame(maxHeight: 340)
            .fixedSize(horizontal: false, vertical: filtered.count < 7)
        }
    }

    @ViewBuilder
    private func menu(for query: SavedQuery) -> some View {
        Button("Open in New Tab") { open(query) }
        Button("Insert at Cursor") { insert(query) }
        Button("Copy SQL") { ResultFiles.copy(query.sql) }
        Divider()
        Button("Rename…") {
            renameText = query.name
            renaming = query
        }
        Button("Replace SQL with Editor Text…") { replacing = query }
            .disabled(editorSQL.isEmpty)
        Button(query.connectionID == nil ? "Show Only for \(tab.profile.name)" : "Show for All Connections") {
            var updated = query
            updated.connectionID = query.connectionID == nil ? tab.profile.id : nil
            saved.update(updated)
        }
        Divider()
        Button("Delete", role: .destructive) { saved.delete(query) }
    }

    private func open(_ query: SavedQuery) {
        tab.openSavedQuery(query)
        tab.showsSavedQueries = false
    }

    private func insert(_ query: SavedQuery) {
        tab.selectedQuery?.editor?.insertAtCursor(query.sql)
        tab.showsSavedQueries = false
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var isReplacing: Binding<Bool> {
        Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } })
    }
}

private struct SavedQueryRow: View {
    let query: SavedQuery
    let open: () -> Void
    let insert: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: query.connectionID == nil ? "globe" : "bookmark.fill")
                .foregroundStyle(query.connectionID == nil ? Color.secondary : Color.accentColor)
                .frame(width: 16)
                .help(query.connectionID == nil ? "Shown for all connections" : "Only this connection")
            VStack(alignment: .leading, spacing: 2) {
                Text(query.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(query.sql.split(whereSeparator: \.isWhitespace).joined(separator: " "))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isHovering {
                Button("Insert at Cursor", systemImage: "text.insert", action: insert)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Insert at the cursor")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(isHovering ? Color.primary.opacity(0.07) : .clear, in: .rect(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .help("Open in a new query tab")
    }
}
