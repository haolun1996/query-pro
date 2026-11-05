import Foundation
import Testing
@testable import SQCore

@Suite struct SchemaScriptTests {
    @Test func dropQuotesEachSchema() {
        #expect(SchemaScript.drop(["shop", "my`db"]) == ["DROP SCHEMA `shop`", "DROP SCHEMA `my``db`"])
        #expect(SchemaScript.text(SchemaScript.drop(["a", "b"])) == "DROP SCHEMA `a`;\nDROP SCHEMA `b`;")
    }

    @Test func alterSetsOnlyWhatIsGiven() {
        #expect(SchemaScript.alter(["a"], charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci")
            == ["ALTER SCHEMA `a` DEFAULT CHARACTER SET utf8mb4 DEFAULT COLLATE utf8mb4_0900_ai_ci"])
        #expect(SchemaScript.alter(["a", "b"], charset: "latin1", collation: nil)
            == ["ALTER SCHEMA `a` DEFAULT CHARACTER SET latin1", "ALTER SCHEMA `b` DEFAULT CHARACTER SET latin1"])
        #expect(SchemaScript.alter(["a"], charset: nil, collation: "") == [])
    }

    @Test func systemSchemas() {
        #expect(SchemaScript.isSystem("mysql"))
        #expect(SchemaScript.isSystem("SYS"))
        #expect(SchemaScript.isSystem("information_schema"))
        #expect(!SchemaScript.isSystem("pos"))
    }

    @Test func scriptsSplitBackIntoStatements() {
        let script = SchemaScript.text(SchemaScript.drop(["a;b", "c"]))
        #expect(SQL.statements(in: script).map(\.text) == ["DROP SCHEMA `a;b`", "DROP SCHEMA `c`"])
    }
}
