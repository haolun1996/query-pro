import Foundation
import Observation
import SQCore

/// One open connection: its sessions, schema tree, query tabs and action log.
///
/// It keeps two sessions: one runs the user's queries, the other loads the schema tree,
/// so a slow query never blocks the sidebar.
@Observable
final class ConnectionTab: Identifiable {
    enum State {
        case connecting
        case connected
        case failed(String)
    }

    enum RunMode {
        /// The selection, or the statement under the cursor.
        case current
        /// The selection, or every statement in the editor.
        case all
    }

    let id = UUID()
    let profile: ConnectionProfile
    private(set) var state = State.connecting
    private(set) var serverVersion = ""
    /// Set when the server rejected the password, so the view can ask for it.
    var needsPassword = false

    // Schema tree
    private(set) var schemas: [SchemaNode] = []
    /// The schema queries run against (`USE …`), shown in bold.
    private(set) var currentSchema: String?
    var sidebarSelection: SchemaSelection?
    var sidebarFilter = ""

    // Query tabs
    private(set) var queries: [QueryDocument] = []
    var selectedQueryID: QueryDocument.ID?
    private var queryCounter = 0

    // Running
    private(set) var isRunning = false
    private(set) var log: [ActionLogEntry] = []
    /// `nil` = Don't Limit.
    var rowLimit: Int?

    private var querySession: MySQLSession?
    private var metaSession: MySQLSession?

    /// MySQL's built-in schemas. Every user can see them, but only root needs them in the sidebar.
    private static let systemSchemas: Set<String> = ["information_schema", "performance_schema", "mysql", "sys"]

    init(profile: ConnectionProfile) {
        self.profile = profile
        self.rowLimit = profile.rowLimit
        newQuery()
    }

    /// "GROUP/Name", like Workbench's connection tabs.
    var title: String {
        guard let group = profile.groupName else { return profile.name }
        return "\(group)/\(profile.name)"
    }

    var selectedQuery: QueryDocument? {
        queries.first { $0.id == selectedQueryID }
    }

    // MARK: Connecting

    /// Connects with the password saved in the Keychain.
    func connect() async {
        await connect(password: await Keychain.password(for: profile.id))
    }

    func connect(password: String?) async {
        state = .connecting
        needsPassword = false
        await disconnect()
        let query = MySQLSession(profile: profile, password: password)
        let meta = MySQLSession(profile: profile, password: password)
        querySession = query
        metaSession = meta
        do {
            try await meta.connect()
            try await query.connect()
            serverVersion = try await meta.execute("SELECT VERSION()").rows.first?.first.flatMap { $0 } ?? ""
            try await reloadSchemas()
            await refreshCurrentSchema()
            state = .connected
        } catch {
            state = .failed(ErrorText.message(for: error))
            needsPassword = ErrorText.isAccessDenied(error)
        }
    }

    func disconnect() async {
        await querySession?.close()
        await metaSession?.close()
        querySession = nil
        metaSession = nil
    }

    // MARK: Schema tree

    func reloadSchemas() async throws {
        guard let metaSession else { return }
        let names = try await metaSession.execute("SHOW DATABASES").rows
            .compactMap { $0.first ?? nil }
            .filter { profile.user == "root" || !Self.systemSchemas.contains($0.lowercased()) }
        let expanded = Set(schemas.filter(\.isExpanded).map(\.name))
        schemas = names.map { SchemaNode(name: $0) }
        for schema in schemas where expanded.contains(schema.name) {
            schema.isExpanded = true
            await loadObjects(of: schema)
        }
    }

    func schemaNode(_ name: String) -> SchemaNode? {
        schemas.first { $0.name == name }
    }

    func tableNode(_ schema: String, _ table: String) -> TableNode? {
        guard let node = schemaNode(schema) else { return nil }
        return (node.tables + node.views).first { $0.name == table }
    }

    /// Loads tables, views and routines the first time a schema is expanded.
    func loadObjects(of schema: SchemaNode, force: Bool = false) async {
        guard let metaSession, force || !schema.isLoaded, !schema.isLoading else { return }
        schema.isLoading = true
        defer { schema.isLoading = false }
        let name = SQL.quoteString(schema.name)
        do {
            let tables = try await metaSession.execute(
                "SELECT TABLE_NAME, TABLE_TYPE FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(name) ORDER BY TABLE_NAME"
            )
            let routines = try await metaSession.execute(
                "SELECT ROUTINE_NAME, ROUTINE_TYPE FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = \(name) ORDER BY ROUTINE_NAME"
            )
            schema.tables = tables.rows.compactMap { row in row[1] == "BASE TABLE" ? row[0].map { TableNode(name: $0) } : nil }
            schema.views = tables.rows.compactMap { row in row[1] == "VIEW" ? row[0].map { TableNode(name: $0, isView: true) } : nil }
            schema.procedures = routines.rows.compactMap { row in row[1] == "PROCEDURE" ? row[0] : nil }
            schema.functions = routines.rows.compactMap { row in row[1] == "FUNCTION" ? row[0] : nil }
            schema.isLoaded = true
        } catch {
            appendLog(action: "Load objects of \(schema.name)", response: ErrorText.message(for: error), status: .error)
        }
    }

    /// Loads a table's columns the first time it is expanded or selected.
    func loadColumns(of table: TableNode, in schema: SchemaNode) async {
        guard let metaSession, table.columns == nil, !table.isLoading else { return }
        table.isLoading = true
        defer { table.isLoading = false }
        do {
            let result = try await metaSession.execute("""
                SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY, COLUMN_DEFAULT, EXTRA, COLUMN_COMMENT
                FROM information_schema.COLUMNS
                WHERE TABLE_SCHEMA = \(SQL.quoteString(schema.name)) AND TABLE_NAME = \(SQL.quoteString(table.name))
                ORDER BY ORDINAL_POSITION
                """)
            table.columns = result.rows.map { row in
                ColumnDetail(
                    name: row[0] ?? "",
                    type: row[1] ?? "",
                    isNullable: row[2] == "YES",
                    key: row[3] ?? "",
                    defaultValue: row[4],
                    extra: row[5] ?? "",
                    comment: row[6] ?? ""
                )
            }
        } catch {
            appendLog(action: "Load columns of \(table.name)", response: ErrorText.message(for: error), status: .error)
        }
    }

    /// `USE schema` on the query session, like Workbench's "Set as Default Schema".
    func setDefaultSchema(_ name: String) {
        Task {
            await execute(["USE \(SQL.quoteIdentifier(name))"], applyLimit: false, document: nil)
        }
    }

    private func refreshCurrentSchema() async {
        guard let querySession else { return }
        currentSchema = (try? await querySession.execute("SELECT DATABASE()"))?.rows.first?.first ?? nil
    }

    // MARK: Query tabs

    @discardableResult
    func newQuery(text: String = "", title: String? = nil) -> QueryDocument {
        queryCounter += 1
        let document = QueryDocument(title: title ?? "Query \(queryCounter)", text: text)
        queries.append(document)
        selectedQueryID = document.id
        return document
    }

    /// Returns `false` when it was the last query tab, so the caller can close the connection instead.
    @discardableResult
    func closeQuery(_ document: QueryDocument) -> Bool {
        guard queries.count > 1, let index = queries.firstIndex(where: { $0.id == document.id }) else { return false }
        queries.remove(at: index)
        if selectedQueryID == document.id {
            selectedQueryID = queries[min(index, queries.count - 1)].id
        }
        return true
    }

    /// Opens (or switches to) the info tab for a table: columns, indexes, foreign keys, triggers, DDL.
    func openTableInfo(_ table: TableNode, in schema: SchemaNode) {
        if let existing = queries.first(where: { $0.tableInfo?.schema == schema.name && $0.tableInfo?.table == table.name }) {
            selectedQueryID = existing.id
            return
        }
        let info = TableInfo(schema: schema.name, table: table.name, isView: table.isView)
        let document = QueryDocument(title: table.name, text: "", tableInfo: info)
        queries.append(document)
        selectedQueryID = document.id
        Task { await loadTableInfo(info) }
    }

    func loadTableInfo(_ info: TableInfo) async {
        guard let metaSession, !info.isLoading else { return }
        info.isLoading = true
        info.error = nil
        defer { info.isLoading = false }
        let schema = SQL.quoteString(info.schema)
        let table = SQL.quoteString(info.table)
        do {
            let summary = try await metaSession.execute("""
                SELECT ENGINE, TABLE_ROWS, TABLE_COLLATION, AUTO_INCREMENT, DATA_LENGTH + INDEX_LENGTH, TABLE_COMMENT
                FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(schema) AND TABLE_NAME = \(table)
                """)
            if let row = summary.rows.first {
                info.summary = TableInfo.Summary(
                    engine: row[0] ?? "",
                    approximateRows: row[1] ?? "",
                    collation: row[2] ?? "",
                    autoIncrement: row[3] ?? "",
                    dataSize: row[4].flatMap(Int64.init).map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "",
                    comment: row[5] ?? ""
                )
            }

            let columns = try await metaSession.execute("""
                SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY, COLUMN_DEFAULT, EXTRA, COLUMN_COMMENT
                FROM information_schema.COLUMNS
                WHERE TABLE_SCHEMA = \(schema) AND TABLE_NAME = \(table)
                ORDER BY ORDINAL_POSITION
                """)
            info.columns = columns.rows.map { row in
                ColumnDetail(
                    name: row[0] ?? "", type: row[1] ?? "", isNullable: row[2] == "YES", key: row[3] ?? "",
                    defaultValue: row[4], extra: row[5] ?? "", comment: row[6] ?? ""
                )
            }

            let indexes = try await metaSession.execute("""
                SELECT INDEX_NAME, NON_UNIQUE, INDEX_TYPE, COLUMN_NAME, INDEX_COMMENT
                FROM information_schema.STATISTICS
                WHERE TABLE_SCHEMA = \(schema) AND TABLE_NAME = \(table)
                ORDER BY INDEX_NAME = 'PRIMARY' DESC, INDEX_NAME, SEQ_IN_INDEX
                """)
            var indexOrder: [String] = []
            var indexRows: [String: [[String?]]] = [:]
            for row in indexes.rows {
                let name = row[0] ?? ""
                if indexRows[name] == nil { indexOrder.append(name) }
                indexRows[name, default: []].append(row)
            }
            info.indexes = indexOrder.map { name in
                let rows = indexRows[name] ?? []
                return TableInfo.Index(
                    name: name,
                    isUnique: rows.first?[1] == "0",
                    type: rows.first?[2] ?? "",
                    columns: rows.map { $0[3] ?? "(expression)" },
                    comment: rows.first?[4] ?? ""
                )
            }

            let foreignKeys = try await metaSession.execute("""
                SELECT k.CONSTRAINT_NAME, k.COLUMN_NAME, k.REFERENCED_TABLE_SCHEMA, k.REFERENCED_TABLE_NAME,
                       k.REFERENCED_COLUMN_NAME, r.UPDATE_RULE, r.DELETE_RULE
                FROM information_schema.KEY_COLUMN_USAGE k
                JOIN information_schema.REFERENTIAL_CONSTRAINTS r
                  ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME
                 AND r.TABLE_NAME = k.TABLE_NAME
                WHERE k.TABLE_SCHEMA = \(schema) AND k.TABLE_NAME = \(table) AND k.REFERENCED_TABLE_NAME IS NOT NULL
                ORDER BY k.CONSTRAINT_NAME, k.ORDINAL_POSITION
                """)
            var keyOrder: [String] = []
            var keyRows: [String: [[String?]]] = [:]
            for row in foreignKeys.rows {
                let name = row[0] ?? ""
                if keyRows[name] == nil { keyOrder.append(name) }
                keyRows[name, default: []].append(row)
            }
            info.foreignKeys = keyOrder.map { name in
                let rows = keyRows[name] ?? []
                let first = rows.first ?? []
                let referencedSchema = first[2] ?? ""
                let referencedTable = first[3] ?? ""
                return TableInfo.ForeignKey(
                    name: name,
                    columns: rows.map { $0[1] ?? "" },
                    referencedTable: referencedSchema == info.schema ? referencedTable : "\(referencedSchema).\(referencedTable)",
                    referencedColumns: rows.map { $0[4] ?? "" },
                    onUpdate: first[5] ?? "",
                    onDelete: first[6] ?? ""
                )
            }

            let triggers = try await metaSession.execute("""
                SELECT TRIGGER_NAME, ACTION_TIMING, EVENT_MANIPULATION, ACTION_STATEMENT
                FROM information_schema.TRIGGERS
                WHERE EVENT_OBJECT_SCHEMA = \(schema) AND EVENT_OBJECT_TABLE = \(table)
                ORDER BY ACTION_TIMING, EVENT_MANIPULATION, ACTION_ORDER
                """)
            info.triggers = triggers.rows.map { row in
                TableInfo.Trigger(name: row[0] ?? "", timing: "\(row[1] ?? "") \(row[2] ?? "")", statement: row[3] ?? "")
            }

            let create = try await metaSession.execute(
                "SHOW CREATE TABLE \(SQL.quoteIdentifier(info.schema)).\(SQL.quoteIdentifier(info.table))"
            )
            info.ddl = create.rows.first.flatMap { $0.count > 1 ? $0[1] : nil } ?? ""
        } catch {
            info.error = ErrorText.message(for: error)
        }
    }

    /// Opens a new query tab with `SELECT * FROM table` and runs it.
    func selectRows(of table: TableNode, in schema: SchemaNode) {
        let sql = "SELECT * FROM \(SQL.quoteIdentifier(schema.name)).\(SQL.quoteIdentifier(table.name));"
        let document = newQuery(text: sql, title: table.name)
        document.selection = NSRange(location: 0, length: 0)
        run(.current)
    }

    // MARK: Running

    func run(_ mode: RunMode) {
        guard let document = selectedQuery, document.tableInfo == nil, !isRunning else { return }
        let text = document.text as NSString
        let selection = document.selection
        let hasSelection = selection.length > 0 && NSMaxRange(selection) <= text.length

        var statements: [String]
        if hasSelection {
            statements = SQL.statements(in: text.substring(with: selection)).map(\.text)
        } else {
            let all = SQL.statements(in: document.text)
            switch mode {
            case .all:
                statements = all.map(\.text)
            case .current:
                statements = SQL.statement(at: selection.location, in: all).map { [$0.text] } ?? []
            }
        }
        guard !statements.isEmpty else { return }
        Task { await execute(statements, applyLimit: true, document: document) }
    }

    /// Stops the running statement with `KILL QUERY` from a second connection.
    func stop() {
        guard isRunning, let querySession else { return }
        Task {
            do {
                try await querySession.cancelRunningQuery()
            } catch {
                appendLog(action: "Stop query", response: ErrorText.message(for: error), status: .error)
            }
        }
    }

    /// Runs statements in order and stops at the first error, like Workbench.
    /// Result sets go to `document`'s result tabs.
    private func execute(_ statements: [String], applyLimit: Bool, document: QueryDocument?) async {
        guard let querySession, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        var newResults: [ResultTab] = []
        for statement in statements {
            let (sql, limited) = applyLimit ? SQL.applyingLimit(rowLimit, to: statement) : (statement, false)
            let entry = appendLog(action: Self.oneLine(sql), response: "Running…", status: .running)
            do {
                let result = try await querySession.execute(sql)
                var response = result.summary
                if limited, result.rows.count == rowLimit { response += " (limited)" }
                updateLog(entry, response: response, status: .success, duration: result.duration)
                if result.hasResultSet, let document {
                    newResults.append(ResultTab(title: document.nextResultTitle(for: result), result: result, appliedLimit: limited ? rowLimit : nil))
                }
            } catch {
                updateLog(entry, response: ErrorText.message(for: error), status: .error, duration: nil)
                break
            }
        }
        if let document, !newResults.isEmpty {
            document.results = newResults
            document.selectedResultID = newResults.first?.id
        }
        await refreshCurrentSchema()
        if statements.contains(where: Self.changesSchemaList) {
            try? await reloadSchemas()
        }
    }

    private static func changesSchemaList(_ sql: String) -> Bool {
        let upper = sql.uppercased()
        return ["CREATE ", "DROP ", "RENAME ", "ALTER "].contains { upper.hasPrefix($0) }
    }

    private static func oneLine(_ sql: String) -> String {
        sql.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    // MARK: Action log

    @discardableResult
    private func appendLog(action: String, response: String, status: ActionLogEntry.Status) -> ActionLogEntry.ID {
        let entry = ActionLogEntry(index: log.count + 1, time: .now, action: action, response: response, status: status)
        log.append(entry)
        return entry.id
    }

    private func updateLog(_ id: ActionLogEntry.ID, response: String, status: ActionLogEntry.Status, duration: Duration?) {
        guard let index = log.firstIndex(where: { $0.id == id }) else { return }
        log[index].response = response
        log[index].status = status
        log[index].duration = duration
    }

    func clearLog() {
        log.removeAll()
    }
}

// MARK: - Supporting models

/// One editor tab inside a connection.
@Observable
final class QueryDocument: Identifiable {
    let id = UUID()
    var title: String
    var text: String
    /// Cursor / selection in UTF-16 offsets, kept in sync by the editor.
    var selection = NSRange(location: 0, length: 0)
    var fileURL: URL?
    /// Set for a table info tab instead of an SQL editor.
    let tableInfo: TableInfo?
    var showsInvisibles = false
    var wrapsLines = false

    // Results of the last run in this tab.
    var results: [ResultTab] = []
    var selectedResultID: ResultTab.ID?
    var resultMode = ResultMode.grid
    private var resultCounters: [String: Int] = [:]

    var selectedResult: ResultTab? {
        results.first { $0.id == selectedResultID }
    }
    /// Lets toolbar commands (beautify, find) reach the editor. Set by the editor view.
    @ObservationIgnored weak var editor: SQLTextView?

    init(title: String, text: String, tableInfo: TableInfo? = nil) {
        self.title = title
        self.text = text
        self.tableInfo = tableInfo
    }

    /// "customer_points 1", "customer_points 2", … numbered per table, like Workbench's result tabs.
    func nextResultTitle(for result: QueryResult) -> String {
        let tables = Set(result.columns.map(\.table).filter { !$0.isEmpty })
        let base = tables.count == 1 ? tables.first! : "Result"
        let number = (resultCounters[base] ?? 0) + 1
        resultCounters[base] = number
        return "\(base) \(number)"
    }
}

/// The views down the right side of the results area.
enum ResultMode: String, CaseIterable, Identifiable {
    case grid = "Result Grid"
    case form = "Form Editor"
    case fieldTypes = "Field Types"
    case stats = "Query Stats"

    var id: Self { self }

    var icon: String {
        switch self {
        case .grid: "tablecells"
        case .form: "list.bullet.rectangle"
        case .fieldTypes: "textformat"
        case .stats: "chart.bar.xaxis"
        }
    }
}

@Observable
final class SchemaNode: Identifiable {
    var id: String { name }
    let name: String
    var isExpanded = false
    var isLoaded = false
    var isLoading = false
    var tables: [TableNode] = []
    var views: [TableNode] = []
    var procedures: [String] = []
    var functions: [String] = []

    init(name: String) {
        self.name = name
    }
}

@Observable
final class TableNode: Identifiable {
    var id: String { name }
    let name: String
    let isView: Bool
    var columns: [ColumnDetail]?
    var isLoading = false

    init(name: String, isView: Bool = false) {
        self.name = name
        self.isView = isView
    }
}

struct ColumnDetail: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var type: String
    var isNullable: Bool
    /// `PRI`, `UNI`, `MUL` or empty.
    var key: String
    var defaultValue: String?
    var extra: String
    var comment: String
}

/// What is selected in the schema tree, shown in the Object Info panel.
enum SchemaSelection: Hashable {
    case schema(String)
    case table(schema: String, table: String)
    case routine(schema: String, name: String, kind: String)

    /// The object's own name, for Copy Name / Send to SQL Editor.
    var name: String {
        switch self {
        case .schema(let name): name
        case .table(_, let table): table
        case .routine(_, let name, _): name
        }
    }
}

struct ActionLogEntry: Identifiable {
    enum Status {
        case running, success, error
    }

    let id = UUID()
    let index: Int
    let time: Date
    let action: String
    var response: String
    var status: Status
    var duration: Duration?
}
