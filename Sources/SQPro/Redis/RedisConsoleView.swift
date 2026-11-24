import AppKit
import SwiftUI
import SQCore

/// A redis-cli style console: type a command, Return runs it, ↑ ↓ walk the history. Deep red on remote hosts, like
/// the SQL editor.
struct RedisConsoleView: View {
    @Bindable var tab: RedisTab
    @FocusState private var inputFocused: Bool
    /// Position in `commandHistory` while walking it with ↑ ↓; `nil` = not walking.
    @State private var historyIndex: Int?

    private var background: Color {
        Color(nsColor: tab.profile.isRemote ? SQLTheme.remoteBackground : .textBackgroundColor)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if tab.console.isEmpty {
                            Text("Type a Redis command, e.g. GET key or HGETALL key. ↑ ↓ recall earlier commands; clear empties this.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(tab.console) { entry in
                            ConsoleEntryView(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: tab.console.last?.reply) {
                    if let last = tab.console.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack(spacing: 6) {
                Text(tab.prompt)
                    .foregroundStyle(.secondary)
                TextField("", text: $tab.consoleInput)
                    .textFieldStyle(.plain)
                    .focused($inputFocused)
                    .onSubmit {
                        historyIndex = nil
                        Task {
                            await tab.runConsole()
                            inputFocused = true
                        }
                    }
                    .onKeyPress(.upArrow) { walkHistory(by: -1) }
                    .onKeyPress(.downArrow) { walkHistory(by: 1) }
                    .disabled(tab.isRunningCommand)
                if tab.isRunningCommand { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .font(.system(size: 12, design: .monospaced))
        .background(background)
        .onAppear { inputFocused = true }
    }

    private func walkHistory(by step: Int) -> KeyPress.Result {
        let history = tab.commandHistory
        guard !history.isEmpty else { return .ignored }
        let next = (historyIndex ?? history.count) + step
        if next >= history.count {
            historyIndex = nil
            tab.consoleInput = ""
        } else {
            historyIndex = max(next, 0)
            tab.consoleInput = history[max(next, 0)]
        }
        return .handled
    }
}

private struct ConsoleEntryView: View {
    let entry: RedisTab.ConsoleEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.prompt).foregroundStyle(.secondary)
                Text(entry.command).bold()
                Spacer(minLength: 8)
                if let duration = entry.duration {
                    Text(duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow, fractionalPart: .show(length: 0))))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if !entry.reply.isEmpty {
                Text(entry.reply)
                    .foregroundStyle(entry.isError ? Color.red : Color.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// New key: name, type, first element, optional expiry. Never replaces an existing key.
struct NewRedisKeySheet: View {
    let tab: RedisTab
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type = "string"
    @State private var first = ""
    @State private var second = ""
    @State private var ttl = ""
    @State private var error: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Key in db\(tab.database)").font(.headline)
            Form {
                TextField("Name", text: $name, prompt: Text("e.g. user:42:profile"))
                Picker("Type", selection: $type) {
                    ForEach(RedisKeySidebar.types, id: \.self) { Text($0).tag($0) }
                }
                switch type {
                case "hash":
                    TextField("Field", text: $first)
                    TextField("Value", text: $second)
                case "zset":
                    TextField("Member", text: $first)
                    TextField("Score", text: $second, prompt: Text("0"))
                case "stream":
                    TextField("Field", text: $first)
                    TextField("Value", text: $second)
                case "string":
                    TextField("Value", text: $first, axis: .vertical)
                        .lineLimit(3...8)
                default:
                    TextField(type == "list" ? "First element" : "First member", text: $first)
                }
                TextField("Expire after (seconds)", text: $ttl, prompt: Text("Never"))
            }
            .formStyle(.grouped)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || name.isEmpty || !isValid)
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    /// Collections can't be empty in Redis, so they need their first element.
    private var isValid: Bool {
        switch type {
        case "string": true
        case "zset": !first.isEmpty && (second.isEmpty || Double(second) != nil)
        default: !first.isEmpty
        }
    }

    private func add() {
        isSaving = true
        let seconds = Int(ttl.trimmingCharacters(in: .whitespaces))
        Task {
            error = await tab.createKey(name: name, type: type, first: Data(first.utf8), second: Data(second.utf8), ttl: seconds)
            isSaving = false
            if error == nil { dismiss() }
        }
    }
}
