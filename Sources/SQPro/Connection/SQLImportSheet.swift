import Foundation
import Observation
import SwiftUI
import SQCore

/// One SQL dump import: the file's statements, the chosen mode and target schema, and how far it got.
@Observable
final class SQLImportJob: Identifiable {
    enum Phase: Equatable {
        case setup
        case running(done: Int, total: Int)
        case finished(String)
        case failed(String)
    }

    let id = UUID()
    let fileURL: URL
    var mode = SQLDump.Mode.structureAndData
    /// Empty: no `USE` first; the file's own `USE` decides.
    var schema: String
    var phase = Phase.setup
    var isCancelled = false
    @ObservationIgnored private let plans: [SQLDump.Mode: SQLDump.Plan]
    let statementCount: Int

    init(fileURL: URL, statements: [SQLDump.Statement], schema: String) {
        self.fileURL = fileURL
        self.schema = schema
        self.statementCount = statements.count
        self.plans = Dictionary(uniqueKeysWithValues: SQLDump.Mode.allCases.map { ($0, SQLDump.plan(statements, mode: $0)) })
        // A dump without CREATE TABLE can only be data.
        if plans[.structureAndData]?.tablesCreated == 0, plans[.dataOnly]?.dataStatements ?? 0 > 0 { mode = .dataOnly }
    }

    var plan: SQLDump.Plan { plans[mode]! }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// Why Import is disabled, if it is.
    var problem: String? {
        if plan.statements.isEmpty {
            return mode == .dataOnly ? "The file has no INSERT, REPLACE, UPDATE or DELETE statements." : "The file has no statements."
        }
        if schema.isEmpty, plan.schemasNamed.isEmpty, !plan.createsSchemas {
            return "Choose a schema: the file doesn't say which one to use."
        }
        return nil
    }
}

/// Import a `.sql` dump: everything (tables and data) or only the rows, into a schema.
struct SQLImportSheet: View {
    let tab: ConnectionTab
    @Bindable var job: SQLImportJob
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
        .frame(width: 560)
        .confirmationDialog("Import into \(tab.profile.name)?", isPresented: $confirmProduction) {
            Button("Import on Production", role: .destructive, action: start)
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
                Text("Import SQL Dump").font(.headline)
                Text("\(job.fileURL.lastPathComponent) · \(count(job.statementCount, "statement"))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    // MARK: Setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Import", selection: $job.mode) {
                Text("Tables and data").tag(SQLDump.Mode.structureAndData)
                Text("Data only").tag(SQLDump.Mode.dataOnly)
            }
            .pickerStyle(.segmented)

            Text(job.mode == .dataOnly
                 ? "Runs only INSERT, REPLACE, UPDATE and DELETE (and the SET / USE they need) into tables that already exist; their triggers fire. One transaction: if anything fails, nothing is imported."
                 : "Runs every statement: creates the tables (replacing them if the dump drops them first), views and routines, then fills them. Stops at the first error; what ran before it stays.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Into schema").gridColumnAlignment(.trailing)
                    Picker("Into schema", selection: $job.schema) {
                        Text("None (the file's own USE)").tag("")
                        Divider()
                        ForEach(tab.schemas.map(\.name).filter { !SchemaScript.isSystem($0) }, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("Runs")
                    Text(summary).foregroundStyle(.secondary)
                }
            }

            if !job.plan.schemasNamed.isEmpty {
                Label("The file switches schema itself (USE \(job.plan.schemasNamed.joined(separator: ", "))); statements after that go there.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text(job.problem ?? "Foreign key checks are off during the import.")
                    .font(.callout)
                    .foregroundStyle(job.problem == nil ? Color.secondary : .orange)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    if tab.profile.color.isProduction { confirmProduction = true } else { start() }
                }
                .keyboardShortcut(.defaultAction)
                .tint(tab.profile.color.isProduction ? .red : .accentColor)
                .disabled(job.problem != nil)
            }
        }
        .padding(16)
    }

    private var summary: String {
        let plan = job.plan
        var parts = [count(plan.statements.count, "statement")]
        if plan.tablesCreated > 0 { parts.append("\(plan.tablesCreated) CREATE TABLE") }
        parts.append("\(plan.dataStatements) with data")
        if plan.skipped > 0 { parts.append("\(plan.skipped) skipped") }
        return parts.joined(separator: " · ")
    }

    private func count(_ number: Int, _ noun: String) -> String {
        "\(number.formatted()) \(noun)\(number == 1 ? "" : "s")"
    }

    private func start() {
        Task { await tab.runDumpImport(job) }
    }

    // MARK: Running and done

    private func progress(done: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
            HStack {
                Text("\(done.formatted()) of \(count(total, "statement"))").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { job.isCancelled = true }
                    .disabled(job.isCancelled)
                    .help(job.mode == .dataOnly ? "Rolls back: nothing is imported" : "Stops after the current statement")
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
                Button("Back to Options") { job.phase = .setup }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}
