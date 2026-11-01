import Foundation
import Testing
@testable import SQCore

@Suite struct ResultExportTests {
    private func column(_ name: String, _ type: String = "VAR_STRING", binary: Bool = false) -> ColumnInfo {
        ColumnInfo(name: name, schema: "pos", table: "admins", originalName: name, typeName: type,
                   isPrimaryKey: false, isNotNull: false, isBinary: binary)
    }

    private var columns: [ColumnInfo] { [column("id", "LONG"), column("name"), column("note")] }
    private let rows: [[String?]] = [["1", "Ali, \"Boss\"", nil], ["2", "", "two\nlines"]]

    @Test func csvQuotesOnlyWhereNeeded() {
        #expect(ResultExport.csv(columns: columns, rows: rows) == "id,name,note\r\n1,\"Ali, \"\"Boss\"\"\",\r\n2,\"\",\"two\nlines\"\r\n")
    }

    @Test func jsonKeepsTypesAndOrder() throws {
        let json = ResultExport.json(columns: columns, rows: rows)
        #expect(json.hasPrefix("[\n  {\"id\": 1, \"name\": \"Ali, \\\"Boss\\\"\", \"note\": null},"))
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        #expect(parsed?.count == 2)
        #expect(parsed?[1]["note"] as? String == "two\nlines")
        #expect(parsed?[0]["id"] as? Int == 1)
    }

    @Test func jsonRenamesRepeatedColumns() {
        let json = ResultExport.json(columns: [column("id", "LONG"), column("id", "LONG")], rows: [["1", "2"]])
        #expect(json == "[\n  {\"id\": 1, \"id_2\": 2}\n]\n")
    }

    @Test func jsonQuotesNumbersJSONCantRead() {
        let json = ResultExport.json(columns: [column("n", "DOUBLE")], rows: [["1e+06"], [".5"]])
        #expect(json == "[\n  {\"n\": 1e+06},\n  {\"n\": \".5\"}\n]\n")
        #expect(ResultExport.json(columns: columns, rows: []) == "[]\n")
    }

    @Test func insertStatements() {
        let sql = ResultExport.insert(into: "`pos`.`admins`", columns: columns, rows: rows)
        #expect(sql == """
            INSERT INTO `pos`.`admins` (`id`, `name`, `note`) VALUES (1, 'Ali, "Boss"', NULL);
            INSERT INTO `pos`.`admins` (`id`, `name`, `note`) VALUES (2, '', 'two
            lines');

            """)
    }

    @Test func savedQueriesRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "sqpro-saved-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SavedQueryStore(fileURL: url)
        #expect(try store.load().isEmpty)
        let queries = [SavedQuery(name: "Admins", sql: "select * from admins", connectionID: UUID())]
        try store.save(queries)
        let loaded = try store.load()
        #expect(loaded.map(\.name) == ["Admins"])
        #expect(loaded.first?.connectionID == queries.first?.connectionID)
    }
}
