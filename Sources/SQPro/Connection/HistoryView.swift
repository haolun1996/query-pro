import SwiftUI
import SQCore

/// Every statement run on this connection, newest first, kept across launches.
/// Double-click opens one in a query tab.
struct HistoryView: View {
    let tab: ConnectionTab
    let search: String
    @State private var selection = Set<HistoryEntry.ID>()

    private static let timeFormat = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
    private static let dayFormat = Date.FormatStyle().day().month(.abbreviated).year()

    var body: some View {
        Table(entries, selection: $selection) {
            TableColumn("") { entry in
                Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(entry.succeeded ? .green : .red)
            }
            .width(18)
            TableColumn("Time") { entry in
                Text(Self.when(entry.executedAt)).monospacedDigit()
            }
            .width(min: 80, ideal: 130, max: 170)
            TableColumn("Schema") { entry in
                Text(entry.schema ?? "").foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 50, ideal: 90, max: 160)
            TableColumn("SQL") { entry in
                Text(Self.oneLine(entry.sql))
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .help(entry.sql)
            }
            .width(min: 160, ideal: 480)
            TableColumn("Response") { entry in
                Text(entry.response)
                    .lineLimit(1)
                    .foregroundStyle(entry.succeeded ? .secondary : Color.red)
                    .help(entry.response)
            }
            .width(min: 100, ideal: 240)
            TableColumn("Duration") { entry in
                Text(entry.duration.map { String(format: "%.3f sec", $0) } ?? "").monospacedDigit()
            }
            .width(min: 60, ideal: 80, max: 120)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .font(.callout)
        .contextMenu(forSelectionType: HistoryEntry.ID.self) { ids in
            Button("Open in New Tab") { open(ids) }
            Button("Insert at Cursor") { tab.selectedQuery?.editor?.insertAtCursor(sql(ids)) }
                .disabled(tab.selectedQuery?.editor == nil)
            Button("Copy SQL") { ResultFiles.copy(sql(ids)) }
            Divider()
            Button("Delete from History") { tab.deleteHistory(ids) }
        } primaryAction: { ids in
            open(ids)
        }
        .overlay {
            if tab.history.isEmpty {
                Text("Queries you run on \(tab.profile.name) show up here.").foregroundStyle(.secondary)
            } else if entries.isEmpty {
                Text("No query matches “\(search)”.").foregroundStyle(.secondary)
            }
        }
        .onAppear { tab.loadHistory() }
    }

    private var entries: [HistoryEntry] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return tab.history }
        return tab.history.filter { $0.sql.localizedCaseInsensitiveContains(needle) || ($0.schema ?? "").localizedCaseInsensitiveContains(needle) }
    }

    /// The selected statements, oldest first, each ending with `;`.
    private func sql(_ ids: Set<HistoryEntry.ID>) -> String {
        tab.history.reversed().filter { ids.contains($0.id) }.map { entry in
            entry.sql.hasSuffix(";") || entry.sql.hasPrefix("--") ? entry.sql : entry.sql + ";"
        }.joined(separator: "\n")
    }

    private func open(_ ids: Set<HistoryEntry.ID>) {
        let text = sql(ids)
        guard !text.isEmpty else { return }
        tab.openSavedQuery(SavedQuery(name: "History", sql: text))
    }

    /// "12:30:05" today, "Yesterday 12:30:05", then the date.
    private static func when(_ date: Date) -> String {
        let time = date.formatted(timeFormat)
        if Calendar.current.isDateInToday(date) { return time }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday \(time)" }
        return "\(date.formatted(dayFormat)) \(time)"
    }

    private static func oneLine(_ sql: String) -> String {
        sql.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }
}

struct HistorySearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search history", text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .frame(width: 220)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 6))
    }
}
