import AppKit
import SwiftUI
import SQCore

/// The selected key: name, type, TTL and size on top, then its value with a viewer and editor for its type.
struct RedisValueView: View {
    @Bindable var tab: RedisTab

    var body: some View {
        if let detail = tab.detail {
            VStack(spacing: 0) {
                RedisKeyHeader(tab: tab, key: detail.key, loaded: detail.loaded)
                Divider()
                if let error = detail.writeError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    Divider()
                }
                content(detail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView {
                Label("No key selected", systemImage: "key")
            } description: {
                Text(tab.serverVersion.isEmpty ? "Pick a key on the left." : "Redis \(tab.serverVersion) · db\(tab.database). Pick a key on the left.")
            }
        }
    }

    @ViewBuilder
    private func content(_ detail: RedisTab.KeyDetail) -> some View {
        if let error = detail.error {
            ContentUnavailableView("Can't load this key", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if let loaded = detail.loaded {
            switch loaded.value {
            case .string(let data):
                RedisStringEditor(tab: tab, key: detail.key, value: data)
                    .id(detail.key.name)
            case .other(let type):
                ContentUnavailableView(
                    "No viewer for \(type)",
                    systemImage: "questionmark.square.dashed",
                    description: Text("Use the console, e.g. JSON.GET for RedisJSON keys.")
                )
            default:
                RedisCollectionView(tab: tab, key: detail.key, loaded: loaded)
            }
        } else {
            ProgressView()
        }
    }
}

// MARK: Header

private struct RedisKeyHeader: View {
    let tab: RedisTab
    let key: RedisKey
    let loaded: RedisLoadedValue?
    @State private var editsTTL = false
    @State private var ttlText = ""
    @State private var renames = false
    @State private var newName = ""
    @State private var renameError: String?

    var body: some View {
        HStack(spacing: 10) {
            RedisTypeBadge(type: key.type)
            Text(key.displayName)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let size { Text(size).foregroundStyle(.secondary).monospacedDigit() }
            Button(ttlLabel, systemImage: "clock") {
                ttlText = key.ttl.map { String(($0 + 999) / 1000) } ?? ""
                editsTTL = true
            }
            .help("Time to live (EXPIRE / PERSIST)")
            .popover(isPresented: $editsTTL, arrowEdge: .bottom) { ttlEditor }
            Button("Rename", systemImage: "pencil") {
                newName = key.displayName
                renameError = nil
                renames = true
            }
            .labelStyle(.iconOnly)
            .help("Rename (RENAMENX: never replaces another key)")
            .popover(isPresented: $renames, arrowEdge: .bottom) { renameEditor }
            Button("Reload", systemImage: "arrow.clockwise") { Task { await tab.loadValue(of: key) } }
                .labelStyle(.iconOnly)
                .help("Reload this key")
            Button("Delete", systemImage: "trash") { Task { await tab.delete(key) } }
                .labelStyle(.iconOnly)
                .help("Delete this key (UNLINK)")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var ttlLabel: String {
        key.ttl.map { RedisBrowser.formatTTL(milliseconds: $0) } ?? "No expiry"
    }

    private var size: String? {
        guard let loaded else { return nil }
        switch loaded.value {
        case .string: return ByteCountFormatter.string(fromByteCount: loaded.total, countStyle: .memory)
        case .other: return nil
        default: return loaded.total == 1 ? "1 item" : "\(loaded.total) items"
        }
    }

    private var ttlEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Expire after").font(.headline)
            HStack {
                TextField("Seconds", text: $ttlText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .onSubmit(applyTTL)
                Text("seconds").foregroundStyle(.secondary)
            }
            HStack {
                Button("Remove Expiry") {
                    editsTTL = false
                    Task { await tab.setTTL(key, seconds: nil) }
                }
                .disabled(key.ttl == nil)
                Spacer()
                Button("Set", action: applyTTL)
                    .keyboardShortcut(.defaultAction)
                    .disabled(Int(ttlText).map { $0 <= 0 } ?? true)
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private func applyTTL() {
        guard let seconds = Int(ttlText), seconds > 0 else { return }
        editsTTL = false
        Task { await tab.setTTL(key, seconds: seconds) }
    }

    private var renameEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename key").font(.headline)
            TextField("New name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(applyRename)
            if let renameError {
                Text(renameError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Rename", action: applyRename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newName.isEmpty || newName == key.displayName || RedisCommand.isBinary(key.name))
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func applyRename() {
        let name = newName
        Task {
            renameError = await tab.rename(key, to: name)
            if renameError == nil { renames = false }
        }
    }
}

// MARK: String

private struct RedisStringEditor: View {
    let tab: RedisTab
    let key: RedisKey
    let value: Data
    @State private var draft: String

    init(tab: RedisTab, key: RedisKey, value: Data) {
        self.tab = tab
        self.key = key
        self.value = value
        _draft = State(initialValue: RedisCommand.isBinary(value) ? RedisCommand.display(value) : String(decoding: value, as: UTF8.self))
    }

    private var isBinary: Bool { RedisCommand.isBinary(value) }
    private var original: String { String(decoding: value, as: UTF8.self) }
    private var isChanged: Bool { !isBinary && draft != original }

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .disabled(isBinary)
            Divider()
            HStack(spacing: 10) {
                if isBinary {
                    Label("Binary value, shown escaped and read-only. Use the console to change it.", systemImage: "lock")
                        .foregroundStyle(.secondary)
                } else if Self.prettyJSON(draft) != nil {
                    Button("Format JSON") { if let pretty = Self.prettyJSON(draft) { draft = pretty } }
                }
                Spacer()
                Button("Revert") { draft = original }
                    .disabled(!isChanged)
                Button("Save") {
                    let text = draft
                    Task { await tab.setString(key, to: Data(text.utf8)) }
                }
                .keyboardShortcut("s", modifiers: [.command])
                .buttonStyle(.glassProminent)
                .tint(tab.profile.color.isProduction ? .red : .accentColor)
                .disabled(!isChanged)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    /// Only for objects and arrays: reformatting `"text"` or `42` isn't worth a button.
    static func prettyJSON(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
              let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let pretty = String(data: data, encoding: .utf8), pretty != text else { return nil }
        return pretty
    }
}

// MARK: Collections

/// One row of a hash, list, set, sorted set or stream.
struct RedisItem: Identifiable, Hashable {
    let id: Int
    /// Hash field, list index, sorted-set score, stream id; empty for sets.
    let label: String
    /// Hash value, list element, set or sorted-set member, stream fields.
    let value: String
    let rawLabel: Data
    let rawValue: Data

    var isBinary: Bool { RedisCommand.isBinary(rawLabel) || RedisCommand.isBinary(rawValue) }
}

private struct RedisCollectionView: View {
    let tab: RedisTab
    let key: RedisKey
    let loaded: RedisLoadedValue
    @State private var selection: RedisItem.ID?
    @State private var editing: RedisItemEdit?
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("Add", systemImage: "plus") { editing = RedisItemEdit(type: key.type, original: nil) }
                    .help(addHelp)
                Button("Edit", systemImage: "pencil") { if let item = selectedItem { editing = RedisItemEdit(type: key.type, original: item) } }
                    .disabled(selectedItem.map { $0.isBinary || key.type == "stream" } ?? true)
                    .help(key.type == "stream" ? "Stream entries can't be changed, only added or deleted" : "Edit the selected item")
                Button("Delete", systemImage: "minus") { if let item = selectedItem { Task { await delete(item) } } }
                    .disabled(selectedItem == nil)
                    .help("Delete the selected item")
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter shown items", text: $filter).textFieldStyle(.plain)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(width: 200)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 6))
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            table
            if loaded.isTruncated {
                Divider()
                Text("Showing the first \(loaded.value.count) of \(loaded.total). Use the console for the rest.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
        }
        .sheet(item: $editing) { edit in
            RedisItemEditor(edit: edit) { first, second in
                await save(edit, first: first, second: second)
            }
        }
    }

    @ViewBuilder
    private var table: some View {
        Table(visibleItems, selection: $selection) {
            TableColumn(labelTitle) { item in
                Text(item.label).font(.system(.callout, design: .monospaced)).lineLimit(1)
            }
            .width(min: 60, ideal: key.type == "list" ? 60 : 180)
            TableColumn(valueTitle) { item in
                Text(item.value).font(.system(.callout, design: .monospaced)).lineLimit(1).textSelection(.enabled)
            }
        }
        .contextMenu(forSelectionType: RedisItem.ID.self) { ids in
            if let id = ids.first, let item = items.first(where: { $0.id == id }) {
                Button("Copy Value") { copy(item.value) }
                if !item.label.isEmpty { Button("Copy \(labelTitle)") { copy(item.label) } }
            }
        } primaryAction: { ids in
            if let id = ids.first, let item = items.first(where: { $0.id == id }), !item.isBinary, key.type != "stream" {
                editing = RedisItemEdit(type: key.type, original: item)
            }
        }
    }

    private var labelTitle: String {
        switch key.type {
        case "hash": "Field"
        case "list": "Index"
        case "zset": "Score"
        case "stream": "ID"
        default: "#"
        }
    }

    private var valueTitle: String {
        switch key.type {
        case "hash": "Value"
        case "stream": "Fields"
        case "list": "Element"
        default: "Member"
        }
    }

    private var addHelp: String {
        switch key.type {
        case "hash": "Add a field (HSET)"
        case "list": "Append an element (RPUSH)"
        case "set": "Add a member (SADD)"
        case "zset": "Add a member with a score (ZADD)"
        default: "Add an entry (XADD *)"
        }
    }

    private var selectedItem: RedisItem? {
        items.first { $0.id == selection }
    }

    private var visibleItems: [RedisItem] {
        let text = filter.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return items }
        return items.filter { $0.label.localizedCaseInsensitiveContains(text) || $0.value.localizedCaseInsensitiveContains(text) }
    }

    private var items: [RedisItem] {
        let show = RedisCommand.display
        switch loaded.value {
        case .hash(let pairs):
            return pairs.enumerated().map { RedisItem(id: $0, label: show($1.field), value: show($1.value), rawLabel: $1.field, rawValue: $1.value) }
        case .list(let elements):
            return elements.enumerated().map { RedisItem(id: $0, label: String($0), value: show($1), rawLabel: Data(String($0).utf8), rawValue: $1) }
        case .set(let members):
            return members.enumerated().map { RedisItem(id: $0, label: String($0 + 1), value: show($1), rawLabel: Data(), rawValue: $1) }
        case .zset(let members):
            return members.enumerated().map { RedisItem(id: $0, label: $1.score, value: show($1.member), rawLabel: Data($1.score.utf8), rawValue: $1.member) }
        case .stream(let entries):
            return entries.enumerated().map { offset, entry in
                let fields = entry.fields.map { "\(show($0.0))=\(show($0.1))" }.joined(separator: "  ")
                return RedisItem(id: offset, label: entry.id, value: fields, rawLabel: Data(entry.id.utf8), rawValue: Data())
            }
        default:
            return []
        }
    }

    private func save(_ edit: RedisItemEdit, first: String, second: String) async -> Bool {
        let (a, b) = (Data(first.utf8), Data(second.utf8))
        let name = key.name
        let w = RedisTab.word
        var commands: [[Data]] = []
        switch (key.type, edit.original) {
        case ("hash", nil):
            commands = [[w("HSET"), name, a, b]]
        case ("hash", let item?):
            commands = [[w("HSET"), name, a, b]]
            if a != item.rawLabel { commands.append([w("HDEL"), name, item.rawLabel]) }
        case ("list", nil):
            commands = [[w("RPUSH"), name, b]]
        case ("list", let item?):
            commands = [[w("LSET"), name, item.rawLabel, b]]
        case ("set", nil):
            commands = [[w("SADD"), name, b]]
        case ("set", let item?):
            commands = [[w("SREM"), name, item.rawValue], [w("SADD"), name, b]]
        case ("zset", nil):
            commands = [[w("ZADD"), name, a, b]]
        case ("zset", let item?):
            commands = [[w("ZADD"), name, a, b]]
            if b != item.rawValue { commands.insert([w("ZREM"), name, item.rawValue], at: 0) }
        case ("stream", _):
            var command = [w("XADD"), name, w(first.isEmpty ? "*" : first)]
            for line in second.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "=", maxSplits: 1)
                command += [Data(parts[0].trimmingCharacters(in: .whitespaces).utf8), Data((parts.count > 1 ? String(parts[1]) : "").utf8)]
            }
            guard command.count > 3 else { return false }
            commands = [command]
        default:
            return false
        }
        guard await tab.write(commands) else { return false }
        await tab.loadValue(of: key)
        return true
    }

    private func delete(_ item: RedisItem) async {
        let name = key.name
        let w = RedisTab.word
        switch key.type {
        case "list":
            await tab.removeListItem(key, at: item.id)
        case "hash":
            await tab.edit(key, [[w("HDEL"), name, item.rawLabel]])
        case "set":
            await tab.edit(key, [[w("SREM"), name, item.rawValue]])
        case "zset":
            await tab.edit(key, [[w("ZREM"), name, item.rawValue]])
        case "stream":
            await tab.edit(key, [[w("XDEL"), name, item.rawLabel]])
        default:
            break
        }
        selection = nil
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct RedisItemEdit: Identifiable {
    let id = UUID()
    let type: String
    /// `nil` when adding.
    let original: RedisItem?
}

/// Add or edit one item: field + value, element, member (+ score), or stream fields.
private struct RedisItemEditor: View {
    let edit: RedisItemEdit
    let save: (String, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var first = ""
    @State private var second = ""
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Form {
                switch edit.type {
                case "hash":
                    TextField("Field", text: $first)
                    valueField("Value")
                case "zset":
                    TextField("Score", text: $first)
                    valueField("Member")
                case "stream":
                    TextField("ID", text: $first, prompt: Text("* (generated)"))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Fields, one field=value per line").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $second)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 100)
                    }
                default:
                    valueField(edit.type == "list" ? "Element" : "Member")
                }
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(edit.original == nil ? "Add" : "Save") {
                    isSaving = true
                    Task {
                        if await save(first, second) { dismiss() }
                        isSaving = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || !isValid)
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear {
            guard let item = edit.original else { return }
            first = edit.type == "hash" || edit.type == "zset" ? item.label : ""
            second = String(decoding: item.rawValue, as: UTF8.self)
        }
    }

    private func valueField(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $second)
                .font(.system(.body, design: .monospaced))
                .frame(height: 90)
        }
    }

    private var title: String {
        let noun = switch edit.type {
        case "hash": "Field"
        case "list": "Element"
        case "stream": "Entry"
        default: "Member"
        }
        return (edit.original == nil ? "Add " : "Edit ") + noun
    }

    private var isValid: Bool {
        switch edit.type {
        case "hash": !first.isEmpty
        case "zset": Double(first) != nil || ["+inf", "-inf"].contains(first.lowercased())
        case "stream": second.contains("=")
        default: true
        }
    }
}
