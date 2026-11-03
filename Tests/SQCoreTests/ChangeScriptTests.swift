import Testing
@testable import SQCore

@Suite struct ChangeScriptTests {
    private func column(_ name: String, _ type: String = "VAR_STRING", original: String? = nil, binary: Bool = false) -> ColumnInfo {
        ColumnInfo(name: name, schema: "shop", table: "wallets", originalName: original ?? name,
                   typeName: type, isPrimaryKey: false, isNotNull: false, isBinary: binary)
    }

    private var columns: [ColumnInfo] {
        [column("id", "LONGLONG"), column("customer_id", "LONG"), column("balance", "NEWDECIMAL"), column("note"), column("display", original: "label")]
    }

    private let rows: [[String?]] = [
        ["10", "73640", "1600", "hi", "A"],
        ["11", "73640", "0", nil, "B"],
        ["18", "73640", "0", "it's", "C"],
    ]

    private func script(_ edits: RowEdits) -> String {
        ChangeScript.build(schema: "shop", table: "wallets", primaryKey: [0], columns: columns, rows: rows, edits: edits)
    }

    @Test func updateUsesNumbersUnquotedAndThePrimaryKey() {
        var edits = RowEdits()
        edits.updates[2] = [2: "1"]
        #expect(script(edits) == "UPDATE `shop`.`wallets` SET `balance` = 1 WHERE `id` = 18;")
    }

    @Test func updateQuotesTextAndWritesRealNull() {
        var edits = RowEdits()
        edits.updates[0] = [3: "it's \"ok\"", 2: nil]
        #expect(script(edits) == "UPDATE `shop`.`wallets` SET `balance` = NULL, `note` = 'it''s \"ok\"' WHERE `id` = 10;")
    }

    @Test func aliasedColumnsUseTheirRealName() {
        var edits = RowEdits()
        edits.updates[1] = [4: "Z"]
        #expect(script(edits) == "UPDATE `shop`.`wallets` SET `label` = 'Z' WHERE `id` = 11;")
    }

    @Test func editingThePrimaryKeyStillFindsTheOriginalRow() {
        var edits = RowEdits()
        edits.updates[0] = [0: "99"]
        #expect(script(edits) == "UPDATE `shop`.`wallets` SET `id` = 99 WHERE `id` = 10;")
    }

    @Test func deleteInsertOrderAndDefaults() {
        var edits = RowEdits()
        edits.deleted = [1]
        edits.updates[1] = [3: "ignored, row is deleted"]
        edits.inserted = [[1: "5", 3: nil], [:]]
        #expect(script(edits) == """
        DELETE FROM `shop`.`wallets` WHERE `id` = 11;
        INSERT INTO `shop`.`wallets` (`customer_id`, `note`) VALUES (5, NULL);
        INSERT INTO `shop`.`wallets` () VALUES ();
        """)
    }

    @Test func compositeKeysAndNullKeys() {
        let keyRows: [[String?]] = [["1", nil, "x", nil, "a"]]
        var edits = RowEdits()
        edits.deleted = [0]
        let sql = ChangeScript.build(schema: "s", table: "t", primaryKey: [0, 1], columns: columns, rows: keyRows, edits: edits)
        #expect(sql == "DELETE FROM `s`.`t` WHERE `id` = 1 AND `customer_id` IS NULL;")
    }

    @Test func literals() {
        let number = column("n", "LONG")
        #expect(ChangeScript.literal("-12", for: number) == "-12")
        #expect(ChangeScript.literal("3.50", for: column("d", "NEWDECIMAL")) == "3.50")
        #expect(ChangeScript.literal("1e6", for: column("f", "DOUBLE")) == "1e6")
        // Not a plain number: quoted so MySQL decides (and nothing gets injected).
        #expect(ChangeScript.literal("12; DROP TABLE x", for: number) == "'12; DROP TABLE x'")
        #expect(ChangeScript.literal("", for: number) == "''")
        #expect(ChangeScript.literal("0x", for: number) == "'0x'")
        #expect(ChangeScript.literal("007", for: column("s")) == "'007'")
        #expect(ChangeScript.literal("0xABCD", for: column("b", "BLOB", binary: true)) == "0xABCD")
        #expect(ChangeScript.literal("0xZZ", for: column("b", "BLOB", binary: true)) == "'0xZZ'")
        #expect(ChangeScript.literal(nil, for: number) == "NULL")
    }
}
