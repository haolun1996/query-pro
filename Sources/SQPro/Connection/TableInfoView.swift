import AppKit
import SwiftUI

/// The table info tab: a summary line, then Columns / Indexes / Foreign Keys / Triggers / DDL.
struct TableInfoView: View {
    @Bindable var info: TableInfo
    let reload: () -> Void
    @AppStorage(SettingsKey.showsDDL) private var showsDDL = true

    private var sections: [TableInfo.Section] {
        TableInfo.Section.allCases.filter { $0 != .ddl || showsDDL }
    }

    /// Falls back to Columns if the DDL section was open when it got switched off.
    private var section: TableInfo.Section {
        sections.contains(info.section) ? info.section : .columns
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = info.error {
                ContentUnavailableView {
                    Label("Couldn't load table info", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error).textSelection(.enabled)
                } actions: {
                    Button("Try Again", action: reload)
                }
            } else {
                content
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: info.isView ? "eye" : "tablecells")
                    .foregroundStyle(.blue)
                Text("\(info.schema).\(info.table)")
                    .font(.title3.bold())
                    .textSelection(.enabled)
                if info.isLoading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise", action: reload)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Reload table info")
            }
            summaryLine
            Picker("Section", selection: $info.section) {
                ForEach(sections) { section in
                    if let count = info.count(of: section) {
                        Text("\(section.rawValue) (\(count))").tag(section)
                    } else {
                        Text(section.rawValue).tag(section)
                    }
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var summaryLine: some View {
        let summary = info.summary
        let parts: [(String, String)] = [
            ("Engine", summary.engine),
            ("Rows (approx.)", summary.approximateRows),
            ("Collation", summary.collation),
            ("Auto increment", summary.autoIncrement),
            ("Size", summary.dataSize),
            ("Comment", summary.comment),
        ].filter { !$0.1.isEmpty }
        return HStack(spacing: 14) {
            ForEach(parts, id: \.0) { label, value in
                HStack(spacing: 4) {
                    Text(label).foregroundStyle(.secondary)
                    Text(value).textSelection(.enabled)
                }
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .columns: columnsTable
        case .indexes: indexesTable
        case .foreignKeys: foreignKeysTable
        case .triggers: triggersTable
        case .ddl: ddlView
        }
    }

    private var columnsTable: some View {
        Table(info.columns) {
            TableColumn("") { column in
                if column.key == "PRI" {
                    Image(systemName: "key.fill").foregroundStyle(.yellow)
                }
            }
            .width(18)
            TableColumn("Name") { Text($0.name) }
            TableColumn("Type") { Text($0.type) }
            TableColumn("Nullable") { Text($0.isNullable ? "YES" : "NO") }
                .width(60)
            TableColumn("Key") { Text($0.key) }
                .width(40)
            TableColumn("Default") { column in
                if let value = column.defaultValue {
                    Text(value)
                } else {
                    Text("NULL").foregroundStyle(.tertiary)
                }
            }
            TableColumn("Extra") { Text($0.extra) }
            TableColumn("Comment") { Text($0.comment) }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .overlay { empty(info.columns.isEmpty, "No columns") }
    }

    private var indexesTable: some View {
        Table(info.indexes) {
            TableColumn("Name") { Text($0.name) }
            TableColumn("Unique") { Text($0.isUnique ? "YES" : "NO") }
                .width(60)
            TableColumn("Type") { Text($0.type) }
                .width(70)
            TableColumn("Columns") { Text($0.columns.joined(separator: ", ")) }
            TableColumn("Comment") { Text($0.comment) }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .overlay { empty(info.indexes.isEmpty, "No indexes") }
    }

    private var foreignKeysTable: some View {
        Table(info.foreignKeys) {
            TableColumn("Name") { Text($0.name) }
            TableColumn("Columns") { Text($0.columns.joined(separator: ", ")) }
            TableColumn("References") { key in
                Text("\(key.referencedTable) (\(key.referencedColumns.joined(separator: ", ")))")
            }
            TableColumn("On Update") { Text($0.onUpdate) }
                .width(90)
            TableColumn("On Delete") { Text($0.onDelete) }
                .width(90)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .overlay { empty(info.foreignKeys.isEmpty, "No foreign keys") }
    }

    private var triggersTable: some View {
        Table(info.triggers) {
            TableColumn("Name") { Text($0.name) }
            TableColumn("Event") { Text($0.timing) }
                .width(130)
            TableColumn("Statement") { trigger in
                Text(trigger.statement)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .help(trigger.statement)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .overlay { empty(info.triggers.isEmpty, "No triggers") }
    }

    private var ddlView: some View {
        VStack(alignment: .trailing, spacing: 0) {
            SQLCodeView(text: info.ddl)
            Divider()
            Button("Copy DDL", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(info.ddl, forType: .string)
            }
            .disabled(info.ddl.isEmpty)
            .padding(8)
        }
    }

    @ViewBuilder
    private func empty(_ isEmpty: Bool, _ text: String) -> some View {
        if isEmpty && !info.isLoading {
            Text(text).foregroundStyle(.secondary)
        }
    }
}
