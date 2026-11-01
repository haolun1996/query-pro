import SwiftUI
import SQCore

/// Map a CSV file's columns onto a table, then import it in one transaction.
struct CSVImportSheet: View {
    let tab: ConnectionTab
    @Bindable var job: CSVImportJob
    @Environment(\.dismiss) private var dismiss
    @State private var confirmProduction = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            switch job.phase {
            case .setup: setup
            case .running(let done, let total): progress(done: done, total: total)
            case .finished(let summary): finished(summary)
            case .failed(let message): failed(message)
            }
        }
        .frame(width: 640)
        .confirmationDialog("Import into \(tab.profile.name)?", isPresented: $confirmProduction) {
            Button("Import \(Self.count(job.dataRows.count, "Row"))", role: .destructive) { start() }
        } message: {
            Text("\(tab.profile.name) is marked as production.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Import CSV into \(job.schema).\(job.table)").font(.headline)
                Text("\(job.fileURL.lastPathComponent) · \(Self.count(job.dataRows.count, "row")) · \(Self.count(job.csvColumnCount, "column"))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    // MARK: Setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Picker("Delimiter", selection: $job.delimiter) {
                    Text("Comma").tag(Character(","))
                    Text("Semicolon").tag(Character(";"))
                    Text("Tab").tag(Character("\t"))
                    Text("Pipe").tag(Character("|"))
                }
                .fixedSize()
                Toggle("First row has column names", isOn: $job.hasHeader)
                if job.isParsing { ProgressView().controlSize(.small) }
            }

            Text("Columns").font(.callout.bold())
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("CSV column").foregroundStyle(.secondary)
                        Text("Sample").foregroundStyle(.secondary)
                        Text("Goes into").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    ForEach(0..<job.csvColumnCount, id: \.self) { index in
                        GridRow {
                            Text(job.headers[index]).lineLimit(1).frame(width: 150, alignment: .leading)
                            Text(job.samples(index))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 200, alignment: .leading)
                            Picker("Goes into", selection: mappingBinding(index)) {
                                Text("Skip").tag(Int?.none)
                                Divider()
                                ForEach(job.columns.indices, id: \.self) { column in
                                    Text("\(job.columns[column].name)  \(job.columns[column].type)").tag(Int?.some(column))
                                }
                            }
                            .labelsHidden()
                            .frame(width: 210)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: job.csvColumnCount < 9)

            Divider()
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Empty fields are NULL", isOn: $job.emptyIsNull)
                        .help("Off: they become empty strings. A quoted \"\" is always an empty string.")
                    Toggle("The text NULL is NULL", isOn: $job.nullText)
                }
                Picker("Duplicate keys", selection: $job.duplicates) {
                    Text("Stop and import nothing").tag(CSVImportPlan.Duplicates.stop)
                    Text("Skip those rows").tag(CSVImportPlan.Duplicates.skip)
                    Text("Replace the existing rows").tag(CSVImportPlan.Duplicates.replace)
                }
                .fixedSize()
            }

            if !job.unfilledRequiredColumns.isEmpty {
                Label("No value for \(job.unfilledRequiredColumns.joined(separator: ", ")), which can't be NULL and has no default.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack {
                Text(job.problem ?? "Runs as one transaction: if any row fails, nothing is imported.")
                    .font(.callout)
                    .foregroundStyle(job.problem == nil ? Color.secondary : .orange)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import \(Self.count(job.dataRows.count, "Row"))") {
                    if tab.profile.color.isProduction { confirmProduction = true } else { start() }
                }
                .keyboardShortcut(.defaultAction)
                .tint(tab.profile.color.isProduction ? .red : .accentColor)
                .disabled(job.problem != nil)
            }
        }
        .padding(16)
    }

    private static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }

    private func mappingBinding(_ index: Int) -> Binding<Int?> {
        Binding(
            get: { index < job.mapping.count ? job.mapping[index] : nil },
            set: { value in
                guard index < job.mapping.count else { return }
                // A table column takes one CSV column: picking it here frees it elsewhere.
                if let value { for other in job.mapping.indices where job.mapping[other] == value { job.mapping[other] = nil } }
                job.mapping[index] = value
            }
        )
    }

    private func start() {
        Task { await tab.runImport(job) }
    }

    // MARK: Running and done

    private func progress(done: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
            HStack {
                Text("\(done) of \(total) rows").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { job.isCancelled = true }
                    .disabled(job.isCancelled)
                    .help("Rolls back: nothing is imported")
            }
        }
        .padding(16)
    }

    private func finished(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(summary, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            HStack {
                Spacer()
                Button("Select Rows") {
                    if let schema = tab.schemaNode(job.schema), let table = tab.tableNode(job.schema, job.table) {
                        tab.selectRows(of: table, in: schema)
                    }
                    dismiss()
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Import failed", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.callout.bold())
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Back to Options") {
                    job.isCancelled = false
                    job.phase = .setup
                }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}
