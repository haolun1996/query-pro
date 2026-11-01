import Foundation
import Testing
@testable import SQCore

@Suite struct CSVImportTests {
    @Test func parsesQuotesNewlinesAndNulls() {
        let text = "\u{FEFF}id,name,note\r\n1,\"Ali, \"\"Boss\"\"\",\r\n2,\"\",\"two\nlines\"\n\n3,\\N,x"
        #expect(CSV.parse(text) == [
            ["id", "name", "note"],
            ["1", "Ali, \"Boss\"", nil],
            ["2", "", "two\nlines"],
            ["3", nil, "x"],
        ])
    }

    @Test func roundTripsSQProsOwnExport() {
        let column = { (name: String) in
            ColumnInfo(name: name, schema: "", table: "", originalName: name, typeName: "VAR_STRING", isPrimaryKey: false, isNotNull: false, isBinary: false)
        }
        let rows: [[String?]] = [["a", nil, ""], [" padded ", "x,y", "q\"uote"]]
        let csv = ResultExport.csv(columns: [column("a"), column("b"), column("c")], rows: rows)
        #expect(Array(CSV.parse(csv).dropFirst()) == rows)
    }

    @Test func detectsTheDelimiter() {
        #expect(CSV.detectDelimiter("a;b;c\n1;2;3") == ";")
        #expect(CSV.detectDelimiter("a\tb\n1\t2") == "\t")
        #expect(CSV.detectDelimiter("\"x;y\",b,c\n") == ",")
        #expect(CSV.detectDelimiter("single") == ",")
        #expect(CSV.parse("a;b\n1;2", delimiter: ";") == [["a", "b"], ["1", "2"]])
    }

    @Test func buildsBatchedInserts() {
        var plan = CSVImportPlan(schema: "pos", table: "admins", targets: [
            .init(column: "name", source: 1), .init(column: "id", source: 0), .init(column: "avatar", source: 2, isBinary: true),
        ])
        let rows: [[String?]] = [["1", "Ali", "0xFF00"], ["2", nil, nil], ["3", "NULL"], ["4", "it's", "0xZZ"]]
        let statements = plan.statements(for: rows, maxRows: 3)
        #expect(statements.map(\.firstRow) == [0, 3])
        #expect(statements[0].sql == """
            INSERT INTO `pos`.`admins` (`name`, `id`, `avatar`) VALUES
            ('Ali', '1', 0xFF00),
            (NULL, '2', NULL),
            (NULL, '3', NULL)
            """)
        #expect(statements[1].sql.hasSuffix("('it''s', '4', '0xZZ')"))

        plan.emptyIsNull = false
        plan.nullText = false
        plan.duplicates = .skip
        let other = plan.statements(for: [["5", nil, nil], ["6", "NULL", nil]])
        #expect(other.count == 1)
        #expect(other[0].sql.hasPrefix("INSERT IGNORE INTO"))
        #expect(other[0].sql.contains("('', '5', '')"))
        #expect(other[0].sql.contains("('NULL', '6', '')"))
    }

    @Test func splitsBySize() {
        let plan = CSVImportPlan(schema: "s", table: "t", targets: [.init(column: "v", source: 0)])
        let rows = (0..<10).map { _ in [String(repeating: "x", count: 100)] as [String?] }
        #expect(plan.statements(for: rows, maxBytes: 350).count == 4)
    }
}

@Suite struct QueryHistoryTests {
    @Test func appendsLoadsAndTrims() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "sqpro-history-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = QueryHistoryStore(fileURL: url)
        #expect(try store.load().isEmpty)
        try store.append([HistoryEntry(sql: "select 1", schema: "pos", succeeded: true, response: "1 row(s) returned", duration: 0.01)])
        try store.append([HistoryEntry(sql: "select nope", schema: nil, succeeded: false, response: "Error Code: 1054.", duration: nil)])
        let loaded = try store.load()
        #expect(loaded.map(\.sql) == ["select 1", "select nope"])
        #expect(loaded[1].succeeded == false)

        let many = (0..<(QueryHistoryStore.limit + 2000)).map {
            HistoryEntry(sql: "select \($0)", schema: nil, succeeded: true, response: "", duration: nil)
        }
        try store.save(many)
        let trimmed = try store.load()
        #expect(trimmed.count == QueryHistoryStore.limit)
        #expect(trimmed.last?.sql == "select \(QueryHistoryStore.limit + 1999)")
    }

    @Test func redactsPasswords() {
        #expect(QueryHistoryStore.redacted("CREATE USER 'ai'@'localhost' IDENTIFIED BY 'se''cret';")
            == "CREATE USER 'ai'@'localhost' IDENTIFIED BY '***';")
        #expect(QueryHistoryStore.redacted("ALTER USER x IDENTIFIED WITH caching_sha2_password BY 'p'")
            == "ALTER USER x IDENTIFIED WITH caching_sha2_password BY '***'")
        #expect(QueryHistoryStore.redacted("SET PASSWORD = 'abc'") == "SET PASSWORD = '***'")
        #expect(QueryHistoryStore.redacted("select * from users where password = 'x'") == "select * from users where password = 'x'")
    }
}
