import SwiftUI
import SQCore

/// Drop / Truncate Tables… from the schema tree: every table of a schema, or the selected ones. Lists them
/// with their row estimate, shows the SQL, then runs it. No default button, so Return can't delete anything.
struct TableChangeSheet: View {
    let tab: ConnectionTab
    let change: TableChange

    @Environment(\.dismiss) private var dismiss
    @State private var tables: [(name: String, rows: Int?)] = []
    @State private var isLoading = true
    @State private var isRunning = false
    @State private var error: String?
    @State private var confirmProduction = false
    /// Statements done and the one running, while it runs.
    @State private var progress: (done: Int, statement: String) = (0, "")

    private var isDrop: Bool { change.kind == .drop }
    private var isProduction: Bool { tab.profile.color.isProduction }
    private var names: [String] { tables.map(\.name) }

    private var title: String {
        let verb = isDrop ? "Drop" : "Truncate"
        if change.tables == nil { return "\(verb) All Tables in \(change.schema)" }
        return names.count == 1 ? "\(verb) Table \(names[0])" : "\(verb) \(names.count) Tables"
    }

    private var statements: [String] {
        isDrop ? SchemaScript.dropTables(names, in: change.schema) : SchemaScript.truncateTables(names, in: change.schema)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.bold())
                Text(isDrop
                     ? "Deletes the tables and all their rows. Views and routines stay. This can't be undone."
                     : "Deletes every row and restarts AUTO_INCREMENT; the tables stay. This can't be undone or rolled back.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isProduction {
                    Label("\(tab.profile.name) is marked as production.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            tableList

            VStack(alignment: .leading, spacing: 4) {
                Text("SQL · foreign key checks are off while it runs").font(.caption).foregroundStyle(.secondary)
                SQLCodeView(text: statements.isEmpty ? "-- No tables" : SchemaScript.text(statements))
                    .frame(height: 110)
                    .clipShape(.rect(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator) }
            }

            if isRunning { progressView }

            if let error {
                Label {
                    Text(error).textSelection(.enabled)
                } icon: {
                    Image(systemName: "xmark.octagon.fill")
                }
                .foregroundStyle(.red)
                Text("Tables before the failing one are already \(isDrop ? "dropped" : "empty").")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isRunning)
                Button(buttonTitle) {
                    if isProduction { confirmProduction = true } else { run() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isRunning || isLoading || names.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { await load() }
        .confirmationDialog("\(title) on \(tab.profile.name)?", isPresented: $confirmProduction) {
            Button("\(buttonTitle) on Production", role: .destructive, action: run)
        } message: {
            Text("This connection is marked as production.")
        }
    }

    private var buttonTitle: String {
        let noun = names.count == 1 ? "Table" : "\(names.count) Tables"
        return "\(isDrop ? "Drop" : "Truncate") \(noun)"
    }

    /// "Dropping orders · 3 of 12 tables".
    private var progressView: some View {
        let total = names.count
        let done = min(max(progress.done - 1, 0), total)
        let table = names.first { progress.statement.hasSuffix("." + SQL.quoteIdentifier($0)) }
        return VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
            Text(table.map { "\(isDrop ? "Dropping" : "Truncating") \($0) · \(done + 1) of \(total) tables" } ?? (progress.done == 0 ? "Starting…" : "Finishing…"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var tableList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if tables.isEmpty {
                    Text("\(change.schema) has no tables.").foregroundStyle(.secondary)
                }
                ForEach(tables, id: \.name) { table in
                    HStack {
                        Label(table.name, systemImage: "tablecells")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(table.rows.map { "~\($0.formatted()) rows" } ?? "")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 180)
        .fixedSize(horizontal: false, vertical: true)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }

    private func load() async {
        let all = await tab.baseTables(of: change.schema)
        if let wanted = change.tables {
            tables = all.filter { wanted.contains($0.name) }
        } else {
            tables = all
        }
        isLoading = false
    }

    private func run() {
        isRunning = true
        error = nil
        progress = (0, "")
        Task {
            let failure = await tab.runTableScript(statements, in: change.schema) { done, statement in
                progress = (done, statement)
            }
            isRunning = false
            if let failure {
                error = failure
                await load()
            } else {
                dismiss()
            }
        }
    }
}
