import Foundation
import MCP
import SQCore
import Testing
@testable import SQMCP

/// A provider with fixed connections that never reach a real server.
private actor FakeProvider: MCPProvider {
    let saved: [ConnectionProfile]
    let approves: Bool
    private(set) var activity: [MCPActivity] = []
    private(set) var approvalRequests: [String] = []

    init(_ saved: [ConnectionProfile], approves: Bool = false) {
        self.saved = saved
        self.approves = approves
    }

    func profiles() async -> [ConnectionProfile] { saved }
    func password(for profile: ConnectionProfile) async -> String? { nil }
    func approveWrite(_ sql: String, on profile: ConnectionProfile) async -> Bool {
        approvalRequests.append(sql)
        return approves
    }
    func record(_ activity: MCPActivity) async { self.activity.append(activity) }
}

@Suite struct SQLToolsTests {
    // Port 1 refuses connections, so anything that gets as far as connecting fails fast instead of hanging.
    let readOnly = ConnectionProfile(name: "Local POS", host: "127.0.0.1", port: 1, mcpAccess: .readOnly)
    let hidden = ConnectionProfile(name: "Secret", host: "127.0.0.1", port: 1, mcpAccess: .hidden)
    let live = ConnectionProfile(name: "LIVE", host: "127.0.0.1", port: 1, color: .red, mcpAccess: .readWrite)

    private func text(_ result: CallTool.Result) -> String {
        guard case .text(let text, _, _) = result.content.first else { return "" }
        return text
    }

    @Test func connectionInfoDescribesOnlyItsOwnConnection() async {
        let provider = FakeProvider([readOnly, hidden, live])
        let info = await SQLTools(provider: provider, connection: readOnly.id).call("connection_info", arguments: [:])
        #expect(text(info).contains("Local POS"))
        #expect(!text(info).contains("LIVE"))
        #expect(text(info).contains("read_only"))
        let entry = await provider.activity.first
        #expect(entry?.connectionID == readOnly.id)
    }

    @Test func hiddenOrDeletedConnectionsAreRefused() async {
        let tools = SQLTools(provider: FakeProvider([readOnly, hidden]), connection: hidden.id)
        #expect(text(await tools.call("connection_info", arguments: [:])).contains("no longer available"))
        let deleted = SQLTools(provider: FakeProvider([readOnly]), connection: UUID())
        #expect(await deleted.call("list_databases", arguments: [:]).isError == true)
    }

    @Test func runQueryRefusesWritesBeforeConnecting() async {
        let provider = FakeProvider([readOnly])
        let tools = SQLTools(provider: provider, connection: readOnly.id)
        for sql in ["delete from t", "select 1; drop table t", "select * from t into outfile '/tmp/x'"] {
            let result = await tools.call("run_query", arguments: ["sql": .string(sql)])
            #expect(result.isError == true)
            #expect(text(result).contains("only runs a single SELECT"), "\(sql)")
        }
        let blocked = await provider.activity.filter { if case .blocked = $0.outcome { true } else { false } }
        #expect(blocked.count == 3)
    }

    @Test func executeNeedsReadWriteAccess() async {
        let tools = SQLTools(provider: FakeProvider([readOnly]), connection: readOnly.id)
        let result = await tools.call("execute", arguments: ["sql": "delete from t"])
        #expect(result.isError == true)
        #expect(text(result).contains("read-only for AI"))
    }

    @Test func executeRunsOneStatementOnly() async {
        let tools = SQLTools(provider: FakeProvider([live], approves: true), connection: live.id)
        let result = await tools.call("execute", arguments: ["sql": "delete from a; delete from b"])
        #expect(text(result).contains("exactly one statement"))
    }

    @Test func productionWritesAskAndCanBeDeclined() async {
        let provider = FakeProvider([live], approves: false)
        let tools = SQLTools(provider: provider, connection: live.id)
        let result = await tools.call("execute", arguments: ["sql": "update t set a = 1"])
        #expect(text(result).contains("declined"))
        #expect(await provider.approvalRequests == ["update t set a = 1"])
    }

    @Test func tableAndImportToolsNeedReadWriteAccess() async {
        let tools = SQLTools(provider: FakeProvider([readOnly]), connection: readOnly.id)
        for (tool, arguments) in [
            ("drop_tables", ["database": Value.string("pos")]),
            ("truncate_tables", ["database": .string("pos")]),
            ("import_sql", ["mode": .string("data_only"), "sql": .string("insert into t values (1)")]),
        ] {
            let result = await tools.call(tool, arguments: arguments)
            #expect(result.isError == true)
            #expect(text(result).contains("read-only for AI"), "\(tool)")
        }
    }

    @Test func tableToolsRefuseSystemDatabases() async {
        let tools = SQLTools(provider: FakeProvider([live], approves: true), connection: live.id)
        let result = await tools.call("drop_tables", arguments: ["database": "mysql"])
        #expect(text(result).contains("system database"))
    }

    @Test func importChecksItsArgumentsBeforeConnecting() async {
        let tools = SQLTools(provider: FakeProvider([live], approves: true), connection: live.id)
        #expect(text(await tools.call("import_sql", arguments: ["mode": "everything", "sql": "select 1"])).contains("mode must be"))
        #expect(text(await tools.call("import_sql", arguments: ["mode": "data_only"])).contains("path or sql"))
        #expect(text(await tools.call("import_sql", arguments: ["mode": "data_only", "path": "/etc/passwd"])).contains(".sql file"))
        #expect(text(await tools.call("import_sql", arguments: ["mode": "data_only", "path": "notes.sql"])).contains(".sql file"))
        let schemaOnly = await tools.call("import_sql", arguments: ["mode": "data_only", "sql": "create table t (a int);"])
        #expect(text(schemaOnly).contains("no data statements"))
    }

    @Test func exportOnlyWritesSQLFiles() async {
        let tools = SQLTools(provider: FakeProvider([readOnly]), connection: readOnly.id)
        for path in ["/tmp/x.txt", "relative.sql", "/Users/me/.zshrc"] {
            let result = await tools.call("export_sql", arguments: ["database": "pos", "content": "data_only", "path": .string(path)])
            #expect(text(result).contains(".sql file"), "\(path)")
        }
        let badContent = await tools.call("export_sql", arguments: ["database": "pos", "content": "all", "path": "/tmp/x.sql"])
        #expect(text(badContent).contains("content must be"))
    }

    @Test func productionImportsAskWithASummary() async {
        let provider = FakeProvider([live], approves: false)
        let tools = SQLTools(provider: provider, connection: live.id)
        let result = await tools.call("import_sql", arguments: [
            "mode": "structure_and_data", "database": "shop", "sql": "create table t (a int); insert into t values (1);",
        ])
        #expect(text(result).contains("declined"))
        let request = await provider.approvalRequests.first ?? ""
        #expect(request.contains("into shop"))
        #expect(request.contains("2 statement(s), 1 CREATE TABLE, 1 data statement(s)"))
        let logged = await provider.activity.first?.sql
        #expect(logged == "-- Import 49 characters of SQL (structure_and_data) into `shop`")
    }

    @Test func eachConnectionOnlyAcceptsItsOwnToken() async {
        let a = UUID(), b = UUID()
        let tokens = [a: "token-a", b: "token-b"]
        let server = MCPHTTPServer(port: 0) { tokens[$0] } makeServer: { _ in Server(name: "t", version: "1") }
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8)
        func post(_ path: String, _ token: String?) async -> Int {
            let headers = token.map { ["Authorization": "Bearer \($0)"] } ?? [:]
            return await server.handle(HTTPRequest(method: "POST", headers: headers, body: body, path: path)).statusCode
        }
        #expect(await post(MCPHTTPServer.path(for: a), nil) == 401)
        #expect(await post(MCPHTTPServer.path(for: a), "nope") == 401)
        // A's token must not open B.
        #expect(await post(MCPHTTPServer.path(for: b), "token-a") == 401)
        // Unknown connection, and the old shared endpoint.
        #expect(await post(MCPHTTPServer.path(for: UUID()), "token-a") == 401)
        #expect(await post("/mcp", "token-a") == 404)
    }

    @Test func detectsInitializeRequests() {
        #expect(MCPHTTPServer.isInitialize(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8)))
        #expect(!MCPHTTPServer.isInitialize(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)))
        #expect(!MCPHTTPServer.isInitialize(Data("not json".utf8)))
    }
}
