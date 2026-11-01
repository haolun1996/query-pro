import SwiftUI
import SQCore

/// Menu items and keyboard shortcuts. They live in the menu bar so they work wherever focus is,
/// including inside the SQL editor.
struct QueryCommands: Commands {
    let workspace: Workspace

    private var tab: ConnectionTab? { workspace.selectedTab }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Query Tab") { tab?.newQuery() }
                .keyboardShortcut("t")
                .disabled(tab == nil)
            Button("Open SQL File…") { if let tab { QueryFiles.open(into: tab) } }
                .keyboardShortcut("o")
                .disabled(tab == nil)
            Divider()
            Button("Close Query Tab") { closeQueryTab() }
                .keyboardShortcut("w")
                .disabled(tab == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Query") { QueryFiles.save(tab?.selectedQuery) }
                .keyboardShortcut("s")
                .disabled(tab?.selectedQuery == nil)
            Button("Save Query As…") { QueryFiles.save(tab?.selectedQuery, saveAs: true) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(tab?.selectedQuery == nil)
            Divider()
            Button("Add to Saved Queries…") {
                tab?.savesNewQuery = true
                tab?.showsSavedQueries = true
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(tab?.selectedQuery == nil || tab?.selectedQuery?.tableInfo != nil)
            Button("Saved Queries…") { tab?.showsSavedQueries.toggle() }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(tab == nil)
            Button("Query History") { tab?.toggleHistory() }
                .keyboardShortcut("y")
                .disabled(tab == nil)
            Button("Import CSV into Table…") { importCSV() }
                .disabled(selectedTable == nil)
        }
        CommandMenu("Query") {
            Button("Execute Current Statement") { tab?.run(.current) }
                .keyboardShortcut(.return)
                .disabled(tab == nil || tab?.isRunning == true)
            Button("Execute All or Selection") { tab?.run(.all) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(tab == nil || tab?.isRunning == true)
            Button("Stop") { tab?.stop() }
                .keyboardShortcut(".")
                .disabled(tab?.isRunning != true)
            Divider()
            Button("Beautify SQL") {
                guard let document = tab?.selectedQuery else { return }
                document.editor?.replaceAll(with: SQL.beautify(document.text))
            }
            .keyboardShortcut("b")
            .disabled(tab?.selectedQuery == nil)
            Button("Show Completions") { tab?.selectedQuery?.editor?.complete(nil) }
                .keyboardShortcut(.escape, modifiers: .option)
                .disabled(tab?.selectedQuery?.editor == nil)
        }
    }

    /// The table selected in the schema tree, for Import CSV.
    private var selectedTable: (SchemaNode, TableNode)? {
        guard let tab, case .table(let schema, let table) = tab.sidebarSelection,
              let schemaNode = tab.schemaNode(schema), let tableNode = tab.tableNode(schema, table), !tableNode.isView
        else { return nil }
        return (schemaNode, tableNode)
    }

    private func importCSV() {
        guard let tab, let (schema, table) = selectedTable else { return }
        tab.importCSV(into: table, in: schema)
    }

    /// Closes the current query tab; closing the last one closes the connection tab.
    private func closeQueryTab() {
        guard let tab, let document = tab.selectedQuery else { return }
        if !tab.closeQuery(document) {
            workspace.close(tab)
        }
    }
}
