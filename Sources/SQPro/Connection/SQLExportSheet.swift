import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import SQCore

/// One SQL dump export: the schema's tables, which ones and what to write, and how far it got.
@Observable
final class SQLExportJob: Identifiable {
    enum Phase: Equatable {
        case setup
        case running(table: String, done: Int, total: Int, rows: Int)
        case finished(String, URL)
        case failed(String)
    }

    let id = UUID()
    let schema: String
    private(set) var tables: [(name: String, rows: Int?)] = []
    var selected: Set<String> = []
    var content = SQLDumpExport.Content.structureAndData
    var includesObjects = true
    private(set) var isLoading = true
    var phase = Phase.setup
    var isCancelled = false

    /// `preselected`: the tables picked in the schema tree; `nil` starts with all of them.
    init(schema: String, preselected: [String]?) {
        self.schema = schema
        self.preselected = preselected
    }

    @ObservationIgnored private let preselected: [String]?

    func load(from tab: ConnectionTab) async {
        tables = await tab.baseTables(of: schema)
        let names = tables.map(\.name)
        selected = Set(preselected.map { $0.filter(names.contains) } ?? names)
        isLoading = false
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// Every table selected means the whole schema, which also brings its views and routines.
    var isWholeSchema: Bool { selected.count == tables.count }

    var options: SQLDumpExport.Options {
        var options = SQLDumpExport.Options(content: content, tables: isWholeSchema ? nil : tables.map(\.name).filter(selected.contains))
        options.includesObjects = includesObjects
        return options
    }

    var suggestedFileName: String {
        let suffix = switch content {
        case .structureAndData: ""
        case .structureOnly: "-structure"
        case .dataOnly: "-data"
        }
        let date = Date().formatted(.iso8601.year().month().day())
        return "\(schema)\(suffix)-\(date).sql"
    }

    var problem: String? {
        if isLoading { return "Loading tables…" }
        if tables.isEmpty, content == .dataOnly || !includesObjects { return "\(schema) has no tables." }
        if !tables.isEmpty, selected.isEmpty { return "Choose at least one table." }
        return nil
    }
}

/// Export a schema as a `.sql` dump: tables and data, tables only, or data only.
struct SQLExportSheet: View {
    let tab: ConnectionTab
    @Bindable var job: SQLExportJob
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            switch job.phase {
            case .setup: setup
            case .running(let table, let done, let total, let rows): progress(table: table, done: done, total: total, rows: rows)
            case .finished(let summary, let url): finished(summary, url)
            case .failed(let message): failed(message)
            }
        }
        .frame(width: 560)
        .task { if job.isLoading { await job.load(from: tab) } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.up.on.square")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Export SQL Dump").font(.headline)
                Text("\(job.schema) · \(tab.profile.address)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    // MARK: Setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Export", selection: $job.content) {
                Text("Tables and data").tag(SQLDumpExport.Content.structureAndData)
                Text("Tables only").tag(SQLDumpExport.Content.structureOnly)
                Text("Data only").tag(SQLDumpExport.Content.dataOnly)
            }
            .pickerStyle(.segmented)

            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(objectsTitle, isOn: $job.includesObjects)
                .disabled(job.content == .dataOnly)

            tableList

            HStack {
                Text(job.problem ?? "Read from one consistent snapshot; the editor stays usable.")
                    .font(.callout)
                    .foregroundStyle(job.problem == nil ? Color.secondary : .orange)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…", action: chooseFile)
                    .keyboardShortcut(.defaultAction)
                    .disabled(job.problem != nil)
            }
        }
        .padding(16)
    }

    private var description: String {
        switch job.content {
        case .structureAndData:
            "CREATE TABLE (after DROP TABLE IF EXISTS) and the rows of each table. Imports back with Tables and data, into a schema of any name."
        case .structureOnly:
            "CREATE TABLE for each table, no rows."
        case .dataOnly:
            "Only the rows, as INSERT statements, for tables that already exist where it's imported (Import › Data only)."
        }
    }

    private var objectsTitle: String {
        job.isWholeSchema ? "Views, stored procedures, functions and triggers" : "Triggers of these tables (views and routines only with every table)"
    }

    private var tableList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Tables").font(.callout.bold())
                Text("\(job.selected.count) of \(job.tables.count)").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("All") { job.selected = Set(job.tables.map(\.name)) }
                Button("None") { job.selected = [] }
            }
            .controlSize(.small)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if job.isLoading { ProgressView().controlSize(.small) }
                    ForEach(job.tables, id: \.name) { table in
                        HStack {
                            Toggle(table.name, isOn: selection(table.name))
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
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: job.tables.count < 10)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
        }
    }

    private func selection(_ name: String) -> Binding<Bool> {
        Binding(
            get: { job.selected.contains(name) },
            set: { on in if on { job.selected.insert(name) } else { job.selected.remove(name) } }
        )
    }

    private func chooseFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.nameFieldStringValue = job.suggestedFileName
        panel.message = "Export \(job.schema) (\(job.content.title))"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await tab.runDumpExport(job, to: url) }
    }

    // MARK: Running and done

    private func progress(table: String, done: Int, total: Int, rows: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
            HStack {
                Text(table.isEmpty ? "Finishing…" : "\(table) · table \(done + 1) of \(total) · \(rows.formatted()) rows so far")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Stop") { job.isCancelled = true }
                    .disabled(job.isCancelled)
                    .help("Stops and deletes the unfinished file")
            }
        }
        .padding(16)
    }

    private func finished(_ summary: String, _ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Exported \(summary)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(url.path)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Export failed", systemImage: "xmark.octagon.fill")
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
