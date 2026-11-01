import Foundation
import Testing
@testable import SQCore

@Suite struct SQLCompletionTests {
    private let catalog = CompletionCatalog(
        schemas: ["pos", "mysapu"],
        currentSchema: "pos",
        tables: [
            "pos": [
                .init(name: "admins", columns: [.init(name: "id", type: "int"), .init(name: "email", type: "varchar(255)")]),
                .init(name: "orders", columns: [.init(name: "id", type: "int"), .init(name: "admin_id", type: "int"), .init(name: "order", type: "int")]),
                .init(name: "order view", isView: true, columns: [.init(name: "total", type: "decimal(10,2)")]),
            ],
        ]
    )

    /// `|` marks the cursor.
    private func complete(_ text: String) -> (request: CompletionRequest?, names: [String]) {
        let cursor = (text as NSString).range(of: "|").location
        let sql = text.replacingOccurrences(of: "|", with: "")
        guard let request = SQLCompletion.request(in: sql, at: cursor) else { return (nil, []) }
        return (request, SQLCompletion.suggestions(for: request, in: catalog).map(\.name))
    }

    @Test func tablesAfterFrom() {
        let (request, names) = complete("select * from ad|")
        #expect(request?.place == .table)
        #expect(request?.prefix == "ad")
        #expect(names == ["admins"])
    }

    @Test func columnsFromTheStatementsTables() {
        let names = complete("select em| from admins").names
        #expect(names.first == "email")
    }

    @Test func aliasQualifiedColumns() {
        let (request, names) = complete("select o.| from orders o join admins a on a.id = o.admin_id")
        #expect(request?.qualifier == ["o"])
        #expect(names == ["id", "admin_id", "order"])
        #expect(complete("select a.e| from orders o join admins as a").names == ["email"])
    }

    @Test func schemaQualifiedTablesAndColumns() {
        #expect(complete("select * from pos.or|").names == ["orders", "order view"])
        #expect(complete("select pos.admins.|").names == ["id", "email"])
    }

    @Test func commaInFromListMeansTable() {
        #expect(complete("select * from admins a, ord|").request?.place == .table)
        #expect(complete("select id, em| from admins").request?.place == .expression)
        #expect(complete("select * from admins where id in (1, |").request?.place == .expression)
    }

    @Test func schemasAfterUse() {
        #expect(complete("use my|").names == ["mysapu"])
    }

    @Test func nothingInsideStringsCommentsOrNumbers() {
        #expect(complete("select 'ad|'").request == nil)
        #expect(complete("select 1 -- ad|").request == nil)
        #expect(complete("select 12|").request == nil)
    }

    @Test func onlyTheStatementUnderTheCursorCounts() {
        let names = complete("select * from orders; select em| from admins").names
        #expect(names.first == "email")
        #expect(!names.contains("admin_id"))
    }

    @Test func replacesTheWholeWordUnderTheCursor() {
        let request = complete("select * from adm|ins").request
        #expect(request?.prefix == "adm")
        #expect(request?.range == 14..<20)
    }

    @Test func quotesNamesThatNeedIt() throws {
        let request = try #require(complete("select * from orders where |").request)
        let items = SQLCompletion.suggestions(for: request, in: catalog)
        #expect(items.first { $0.name == "order" }?.insertion == "`order`")
        #expect(items.first { $0.name == "admin_id" }?.insertion == "admin_id")
        #expect(items.first { $0.name == "order view" }?.insertion == "`order view`")
    }

    @Test func backtickStartedNames() throws {
        let request = try #require(complete("select * from `ad|").request)
        #expect(request.isQuoted)
        #expect(request.range == 14..<17)
        #expect(SQLCompletion.suggestions(for: request, in: catalog).first?.insertion == "`admins`")
    }

    @Test func keywordCaseFollowsTyping() throws {
        let lower = try #require(complete("sel|").request)
        #expect(SQLCompletion.suggestions(for: lower, in: catalog).first?.insertion == "select")
        let upper = try #require(complete("SEL|").request)
        #expect(SQLCompletion.suggestions(for: upper, in: catalog).first?.insertion == "SELECT")
    }

    @Test func noPopupForACompletedWord() {
        #expect(complete("select * from admins|").names.isEmpty)
    }

    @Test func substringMatchesComeAfterPrefixMatches() {
        let names = complete("select * from orders where id|").names
        #expect(names.first == "id")
        #expect(names.contains("admin_id"))
    }

    @Test func schemasToLoad() throws {
        let request = try #require(complete("select * from mysapu.|").request)
        #expect(SQLCompletion.schemasToLoad(for: request, in: catalog) == ["mysapu"])
    }
}

@Suite struct SQLCompletionNoDefaultSchemaTests {
    @Test func aliasOfSchemaQualifiedTable() throws {
        let catalog = CompletionCatalog(
            schemas: ["pos"], currentSchema: nil,
            tables: ["pos": [.init(name: "admins", columns: [.init(name: "id", type: "int"), .init(name: "email", type: "varchar")])]]
        )
        let sql = "select a.em from pos.admins a where a."
        let request = try #require(SQLCompletion.request(in: sql, at: (sql as NSString).length))
        #expect(request.qualifier == ["a"])
        #expect(request.tables == [TableReference(schema: "pos", name: "admins", alias: "a")])
        #expect(SQLCompletion.suggestions(for: request, in: catalog).map(\.name) == ["id", "email"])
    }
}
