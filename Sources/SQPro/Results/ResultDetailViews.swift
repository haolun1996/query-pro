import AppKit
import SwiftUI
import SQCore

/// One row at a time as label / value pairs, following the grid's selection.
struct FormEditorView: View {
    let resultTab: ResultTab

    var body: some View {
        if resultTab.visibleRows.isEmpty {
            ContentUnavailableView("No rows", systemImage: "list.bullet.rectangle")
        } else {
            VStack(spacing: 0) {
                navigation
                Divider()
                ScrollView {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                        ForEach(Array(resultTab.result.columns.enumerated()), id: \.offset) { index, column in
                            GridRow {
                                Text(column.name)
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                                if resultTab.canEdit(column: index) && resultTab.rowState(atVisibleRow: row) != .deleted {
                                    FormField(resultTab: resultTab, row: row, column: index)
                                } else {
                                    value(resultTab.value(atVisibleRow: row, column: index))
                                }
                                Text(column.typeName.lowercased())
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// The first selected row, or the first row.
    private var row: Int {
        min(resultTab.selectedRows.first ?? 0, resultTab.visibleRows.count - 1)
    }

    private var navigation: some View {
        HStack {
            Button("Previous Row", systemImage: "chevron.left") { select(row - 1) }
                .disabled(row == 0)
            Text("Row \(row + 1) of \(resultTab.visibleRows.count)")
                .monospacedDigit()
            Button("Next Row", systemImage: "chevron.right") { select(row + 1) }
                .disabled(row >= resultTab.visibleRows.count - 1)
            Spacer()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func value(_ value: String?) -> some View {
        if let value {
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("NULL")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.quaternary, in: .rect(cornerRadius: 3))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func select(_ row: Int) {
        resultTab.selectedRows = IndexSet(integer: row)
    }
}

/// One editable value in the Form Editor. Multi-line text is fine here; NULL has its own button.
private struct FormField: View {
    let resultTab: ResultTab
    let row: Int
    let column: Int
    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var current: String? { resultTab.value(atVisibleRow: row, column: column) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            TextField(current == nil ? "NULL" : "", text: $text, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...8)
                .focused($isFocused)
                .onSubmit(commit)
                .onChange(of: isFocused) { if !isFocused { commit() } }
                .background(resultTab.isEdited(atVisibleRow: row, column: column) ? Color.blue.opacity(0.25) : .clear,
                            in: .rect(cornerRadius: 5))
            Button("NULL") {
                resultTab.setValue(nil, atVisibleRow: row, column: column)
                text = ""
            }
            .controlSize(.small)
            .disabled(current == nil)
            .help("Set to NULL")
        }
        .onAppear { text = current ?? "" }
        .onChange(of: row) { text = current ?? "" }
        .onChange(of: resultTab.version) { if !isFocused { text = current ?? "" } }
    }

    private func commit() {
        // An untouched NULL stays NULL instead of becoming ''.
        if current == nil && text.isEmpty { return }
        resultTab.setValue(text, atVisibleRow: row, column: column)
    }
}

/// What MySQL reported about each result column.
struct FieldTypesView: View {
    let result: QueryResult

    private struct Field: Identifiable {
        let id: Int
        let column: ColumnInfo
    }

    var body: some View {
        Table(result.columns.enumerated().map { Field(id: $0.offset, column: $0.element) }) {
            TableColumn("#") { Text("\($0.id + 1)").monospacedDigit() }
                .width(30)
            TableColumn("Field") { Text($0.column.name) }
            TableColumn("Schema") { Text($0.column.schema) }
            TableColumn("Table") { Text($0.column.table) }
            TableColumn("Type") { Text($0.column.typeName) }
            TableColumn("Primary Key") { Text($0.column.isPrimaryKey ? "YES" : "") }
                .width(80)
            TableColumn("Not Null") { Text($0.column.isNotNull ? "YES" : "") }
                .width(70)
            TableColumn("Binary") { Text($0.column.isBinary ? "YES" : "") }
                .width(60)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .font(.callout)
    }
}

/// Timing and size of the query that produced this result.
struct QueryStatsView: View {
    let resultTab: ResultTab

    var body: some View {
        let result = resultTab.result
        ScrollView {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                stat("Executed at", resultTab.executedAt.formatted(date: .abbreviated, time: .standard))
                stat("Duration", Self.format(result.duration))
                stat("Rows returned", "\(result.rows.count)")
                stat("Columns", "\(result.columns.count)")
                stat("Row limit", resultTab.appliedLimit.map { resultTab.isLimited ? "\($0) (reached)" : "\($0)" } ?? "None")
                stat("Tables", tables(in: result))
                GridRow {
                    Text("Statement")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(result.sql)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .monospacedDigit()
                .textSelection(.enabled)
        }
    }

    private func tables(in result: QueryResult) -> String {
        let names = Set(result.columns.compactMap { column -> String? in
            guard !column.table.isEmpty else { return nil }
            return column.schema.isEmpty ? column.table : "\(column.schema).\(column.table)"
        })
        return names.isEmpty ? "—" : names.sorted().joined(separator: ", ")
    }

    private static func format(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.3f sec", seconds)
    }
}
