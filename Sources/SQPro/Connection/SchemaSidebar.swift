import AppKit
import SwiftUI
import SQCore

/// SCHEMAS tree: schema › Tables / Views / Stored Procedures / Functions › objects › columns.
struct SchemaSidebar: View {
    @Bindable var tab: ConnectionTab

    var body: some View {
        VStack(spacing: 0) {
            header
            List(selection: $tab.sidebarSelection) {
                ForEach(visibleSchemas) { schema in
                    SchemaRow(tab: tab, schema: schema, filter: filter)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 22)
            .contextMenu(forSelectionType: SchemaSelection.self) { items in
                if let item = items.first { menu(for: item) }
            } primaryAction: { items in
                // Double-click (or Return) on a row.
                if let item = items.first { open(item) }
            }

            Divider()
            ObjectInfoPanel(tab: tab)
                .frame(height: 150)
        }
        .background(.regularMaterial, ignoresSafeAreaEdges: [])
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("SCHEMAS")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                MCPConnectionButton(tab: tab)
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { try? await tab.reloadSchemas() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Refresh schemas")
            }
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter objects", text: $tab.sidebarFilter)
                    .textFieldStyle(.plain)
                if !tab.sidebarFilter.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { tab.sidebarFilter = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 6))
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var filter: String {
        tab.sidebarFilter.trimmingCharacters(in: .whitespaces)
    }

    /// Double-click: schema → default schema, table → select rows, anything else → name into the editor.
    private func open(_ item: SchemaSelection) {
        switch item {
        case .schema(let name):
            tab.setDefaultSchema(name)
        case .table(let schema, let table):
            if let schemaNode = tab.schemaNode(schema), let tableNode = tab.tableNode(schema, table) {
                tab.selectRows(of: tableNode, in: schemaNode)
            }
        case .routine:
            sendToEditor(item)
        }
    }

    @ViewBuilder
    private func menu(for item: SchemaSelection) -> some View {
        switch item {
        case .schema(let name):
            Button("Set as Default Schema") { tab.setDefaultSchema(name) }
            Button("Refresh") {
                if let schema = tab.schemaNode(name) { Task { await tab.loadObjects(of: schema, force: true) } }
            }
        case .table(let schema, let table):
            Button(tab.rowLimit.map { "Select Rows - Limit \($0)" } ?? "Select Rows") { open(item) }
            Button("Table Info") {
                if let schemaNode = tab.schemaNode(schema), let tableNode = tab.tableNode(schema, table) {
                    tab.openTableInfo(tableNode, in: schemaNode)
                }
            }
            if let schemaNode = tab.schemaNode(schema), let tableNode = tab.tableNode(schema, table), !tableNode.isView {
                Button("Import CSV…") { tab.importCSV(into: tableNode, in: schemaNode) }
            }
        case .routine:
            EmptyView()
        }
        Divider()
        Button("Copy Name") { copy(item.name) }
        Button("Send to SQL Editor") { sendToEditor(item) }
    }

    private func sendToEditor(_ item: SchemaSelection) {
        tab.selectedQuery?.editor?.insertAtCursor(SQL.quoteIdentifier(item.name))
    }

    /// With a filter: schemas whose name matches, or that have a loaded object that matches.
    private var visibleSchemas: [SchemaNode] {
        guard !filter.isEmpty else { return tab.schemas }
        return tab.schemas.filter { schema in
            schema.name.localizedCaseInsensitiveContains(filter) || SchemaRow.hasMatch(schema, filter)
        }
    }
}

private struct SchemaRow: View {
    let tab: ConnectionTab
    @Bindable var schema: SchemaNode
    let filter: String

    var body: some View {
        DisclosureGroup(isExpanded: expanded) {
            if schema.isLoading && !schema.isLoaded {
                ProgressView().controlSize(.small).listRowSeparator(.hidden)
            }
            CategoryRow(title: "Tables", icon: "tablecells", count: schema.tables.count) {
                ForEach(filtered(schema.tables)) { table in
                    TableRow(tab: tab, schema: schema, table: table)
                        .listRowSeparator(.hidden)
                }
            }
            .listRowSeparator(.hidden)
            CategoryRow(title: "Views", icon: "eye", count: schema.views.count) {
                ForEach(filtered(schema.views)) { view in
                    TableRow(tab: tab, schema: schema, table: view)
                        .listRowSeparator(.hidden)
                }
            }
            .listRowSeparator(.hidden)
            CategoryRow(title: "Stored Procedures", icon: "gearshape", count: schema.procedures.count) {
                ForEach(filtered(schema.procedures), id: \.self) { name in
                    routineRow(name, kind: "PROCEDURE", icon: "gearshape")
                        .listRowSeparator(.hidden)
                }
            }
            .listRowSeparator(.hidden)
            CategoryRow(title: "Functions", icon: "function", count: schema.functions.count) {
                ForEach(filtered(schema.functions), id: \.self) { name in
                    routineRow(name, kind: "FUNCTION", icon: "function")
                        .listRowSeparator(.hidden)
                }
            }
            .listRowSeparator(.hidden)
        } label: {
            Label {
                Text(schema.name)
                    .fontWeight(tab.currentSchema == schema.name ? .bold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: "cylinder.split.1x2")
            }
            .tag(SchemaSelection.schema(schema.name))
        }
        .onChange(of: filter, initial: true) {
            // Filtering opens schemas that contain matches.
            if !filter.isEmpty, Self.hasMatch(schema, filter) { schema.isExpanded = true }
        }
    }

    private var expanded: Binding<Bool> {
        Binding(
            get: { schema.isExpanded },
            set: { open in
                schema.isExpanded = open
                if open { Task { await tab.loadObjects(of: schema) } }
            }
        )
    }

    private func routineRow(_ name: String, kind: String, icon: String) -> some View {
        Label {
            Text(name).lineLimit(1).truncationMode(.tail)
        } icon: {
            Image(systemName: icon)
        }
        .help(name)
        .tag(SchemaSelection.routine(schema: schema.name, name: name, kind: kind))
    }

    private func filtered(_ tables: [TableNode]) -> [TableNode] {
        filter.isEmpty ? tables : tables.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    private func filtered(_ names: [String]) -> [String] {
        filter.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    static func hasMatch(_ schema: SchemaNode, _ filter: String) -> Bool {
        (schema.tables + schema.views).contains { $0.name.localizedCaseInsensitiveContains(filter) }
            || (schema.procedures + schema.functions).contains { $0.localizedCaseInsensitiveContains(filter) }
    }
}

private struct CategoryRow<Content: View>: View {
    let title: String
    let icon: String
    let count: Int
    @ViewBuilder let content: Content
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
        } label: {
            Label(title, systemImage: icon)
                .badge(count > 0 ? Text("\(count)") : nil)
        }
    }
}

/// A table or view. Hovering shows an ⓘ button that opens its info tab.
private struct TableRow: View {
    let tab: ConnectionTab
    let schema: SchemaNode
    @Bindable var table: TableNode
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Label {
                Text(table.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: table.isView ? "eye" : "tablecells")
            }
            .help(table.name)
            Spacer(minLength: 0)
            Button("Table Info", systemImage: "info.circle") {
                tab.openTableInfo(table, in: schema)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .opacity(isHovering ? 1 : 0)
            .help("Columns, indexes, foreign keys, triggers and DDL")
        }
        .tag(SchemaSelection.table(schema: schema.name, table: table.name))
        .onHover { isHovering = $0 }
    }
}

/// The panel under the tree describing whatever is selected.
private struct ObjectInfoPanel: View {
    let tab: ConnectionTab

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Object Info")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            ScrollView {
                content
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .textSelection(.enabled)
            }
        }
        .task(id: tab.sidebarSelection) { await loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch tab.sidebarSelection {
        case nil:
            Text("No object selected").foregroundStyle(.secondary)
        case .schema(let name):
            let schema = tab.schemas.first { $0.name == name }
            VStack(alignment: .leading, spacing: 3) {
                Text("Schema: \(name)").bold()
                if let schema, schema.isLoaded {
                    Text("\(schema.tables.count) tables, \(schema.views.count) views")
                    Text("\(schema.procedures.count) procedures, \(schema.functions.count) functions")
                }
                if tab.currentSchema == name { Text("Default schema").foregroundStyle(.secondary) }
            }
        case .table(let schemaName, let tableName):
            let table = findTable(schemaName, tableName)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(table?.isView == true ? "View" : "Table"): \(tableName)").bold()
                Text("Columns:").foregroundStyle(.secondary).padding(.top, 2)
                ForEach(table?.columns ?? []) { column in
                    HStack(spacing: 6) {
                        Text(column.name)
                        Spacer(minLength: 4)
                        Text(column.type + (column.key == "PRI" ? " PK" : "")).foregroundStyle(.secondary)
                    }
                }
            }
        case .routine(_, let name, let kind):
            Text("\(kind == "FUNCTION" ? "Function" : "Procedure"): \(name)").bold()
        }
    }

    private func findTable(_ schema: String, _ table: String) -> TableNode? {
        tab.tableNode(schema, table)
    }

    private func loadIfNeeded() async {
        guard case .table(let schemaName, let tableName) = tab.sidebarSelection,
              let schema = tab.schemas.first(where: { $0.name == schemaName }),
              let table = findTable(schemaName, tableName)
        else { return }
        await tab.loadColumns(of: table, in: schema)
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
