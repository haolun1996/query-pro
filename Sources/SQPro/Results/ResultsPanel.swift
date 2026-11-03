import SwiftUI
import SQCore

/// The results area of a query tab: header, the selected view, result tabs, and the side tabs.
struct ResultsPanel: View {
    let tab: ConnectionTab
    @Bindable var document: QueryDocument
    @State private var applying: ResultTab?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if let result = document.selectedResult {
                    header(result)
                    Divider()
                    content(result)
                        .id(result.id)
                } else {
                    ContentUnavailableView("No results", systemImage: "tablecells", description: Text("Run a query with ⌘↩"))
                }
                Divider()
                HStack(spacing: 6) {
                    ResultTabBar(document: document)
                    if let result = document.selectedResult, result.isEditable {
                        Button("Revert") { result.revert() }
                            .disabled(!result.hasChanges)
                            .help("Discard all changes in this result")
                        Button("Apply") { applying = result }
                            .buttonStyle(.borderedProminent)
                            .tint(tab.profile.color.isProduction ? .red : .accentColor)
                            .disabled(!result.hasChanges || tab.isRunning)
                            .help("Review and run the changes")
                    }
                }
                .controlSize(.small)
                .padding(.trailing, 8)
            }
            Divider()
            SideTabs(selection: $document.resultMode)
        }
        .sheet(item: $applying) { result in
            ApplyChangesSheet(tab: tab, document: document, resultTab: result)
        }
    }

    private func header(_ result: ResultTab) -> some View {
        HStack(spacing: 10) {
            Text(document.resultMode.rawValue)
                .font(.callout.bold())
            if document.resultMode == .grid || document.resultMode == .form {
                FilterRowsField(text: Bindable(result).filter)
                EditButtons(result: result)
            }
            Spacer()
            Text(result.countText)
                .font(.callout)
                .foregroundStyle(result.isLimited ? .orange : .secondary)
                .help(result.isLimited ? "The row limit was reached. Choose a higher limit to see more." : "")
            ExportMenu(result: result)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func content(_ result: ResultTab) -> some View {
        switch document.resultMode {
        case .grid:
            ResultGrid(resultTab: result) { row in
                // Multi-line values are easier to edit in the Form Editor.
                result.selectedRows = IndexSet(integer: row)
                document.resultMode = .form
            }
        case .form: FormEditorView(resultTab: result)
        case .fieldTypes: FieldTypesView(result: result.result)
        case .stats: QueryStatsView(resultTab: result)
        }
    }
}

/// "Edit: + −" next to Filter Rows, or why the result is read-only.
private struct EditButtons: View {
    let result: ResultTab

    var body: some View {
        if result.isEditable {
            HStack(spacing: 2) {
                Text("Edit:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Add Row", systemImage: "plus.rectangle") {
                    if let row = result.insertRow(), let column = result.firstEditableColumn {
                        result.pendingEdit = (row, column)
                    }
                }
                .help("Add a row")
                Button("Delete Rows", systemImage: "minus.rectangle") {
                    result.deleteRows(result.selectedRows)
                }
                .disabled(result.selectedRows.isEmpty)
                .help("Delete the selected rows (Delete key)")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        } else if let reason = result.readOnlyReason {
            Label("Read Only", systemImage: "lock")
                .font(.callout)
                .foregroundStyle(.secondary)
                .help(reason)
        }
    }
}

private struct FilterRowsField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(.secondary)
            TextField("Filter Rows", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(width: 220)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 6))
    }
}

/// Saves or copies the whole result (filter and sort applied) as CSV, JSON or INSERT statements.
private struct ExportMenu: View {
    let result: ResultTab

    var body: some View {
        Menu {
            Section("Export to File") {
                ForEach(ResultExport.Format.allCases, id: \.self) { format in
                    Button("\(format.title)…") { ResultFiles.export(result, as: format) }
                }
            }
            Section("Copy") {
                ForEach(ResultExport.Format.allCases, id: \.self) { format in
                    Button("Copy as \(format.title)") { ResultFiles.copy(result.export(format)) }
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(result.result.columns.isEmpty)
        .help("Export or copy the rows shown, as CSV, JSON or SQL INSERT")
    }
}

/// "wallets 1  wallets 2" under the results.
private struct ResultTabBar: View {
    let document: QueryDocument

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(document.results) { result in
                    let isSelected = document.selectedResultID == result.id
                    Text(result.title)
                        .font(.callout)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .background(isSelected ? Color.primary.opacity(0.1) : .clear, in: .rect(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture { document.selectedResultID = result.id }
                }
            }
            .padding(.horizontal, 6)
        }
        .scrollIndicators(.never)
        .frame(height: 28)
    }
}

/// Result Grid / Form Editor / Field Types / Query Stats, stacked down the right edge.
private struct SideTabs: View {
    @Binding var selection: ResultMode

    var body: some View {
        VStack(spacing: 4) {
            ForEach(ResultMode.allCases) { mode in
                let isSelected = selection == mode
                VStack(spacing: 3) {
                    Image(systemName: mode.icon)
                        .font(.title3)
                    Text(mode.rawValue)
                        .font(.system(size: 9))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .frame(width: 62, height: 52)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.clear)
                            .glassEffect(.regular, in: .rect(cornerRadius: 8, style: .continuous))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { selection = mode }
                .help(mode.rawValue)
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }
}
