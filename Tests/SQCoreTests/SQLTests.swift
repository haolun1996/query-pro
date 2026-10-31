import Testing
@testable import SQCore

@Suite struct SQLTests {
    @Test func splitsOnSemicolonsOutsideStringsAndComments() {
        let script = """
        select * from sales where id = 48829;

        -- a comment; not a split
        select 'a;b', `we;ird` from t /* ; */ where x = "q;";
        update t set a = 1
        """
        let statements = SQL.statements(in: script)
        #expect(statements.map(\.text) == [
            "select * from sales where id = 48829",
            "select 'a;b', `we;ird` from t /* ; */ where x = \"q;\"",
            "update t set a = 1",
        ])
    }

    @Test func skipsCommentOnlyChunks() {
        #expect(SQL.statements(in: "-- nothing here\n;  /* still nothing */ ;").isEmpty)
    }

    @Test func handlesEscapedQuotes() {
        let statements = SQL.statements(in: "select 'it''s; fine', 'back\\'slash;'; select 2;")
        #expect(statements.count == 2)
    }

    @Test func statementUnderCursor() {
        let script = "select 1;\n\nselect 2;"
        let statements = SQL.statements(in: script)
        #expect(SQL.statement(at: 3, in: statements)?.text == "select 1")
        // Right after the `;` still means the first statement.
        #expect(SQL.statement(at: 9, in: statements)?.text == "select 1")
        // On the blank line between them: the one above.
        #expect(SQL.statement(at: 10, in: statements)?.text == "select 1")
        #expect(SQL.statement(at: 13, in: statements)?.text == "select 2")
    }

    @Test func addsLimitOnlyWhereSafe() {
        #expect(SQL.applyingLimit(1000, to: "select * from t").sql == "select * from t\nLIMIT 1000")
        #expect(SQL.applyingLimit(1000, to: "select * from t -- note").sql == "select * from t -- note\nLIMIT 1000")
        #expect(!SQL.applyingLimit(1000, to: "select * from t limit 5").limited)
        #expect(SQL.applyingLimit(1000, to: "select * from (select * from t limit 5) x").limited)
        #expect(!SQL.applyingLimit(1000, to: "select * from t for update").limited)
        #expect(!SQL.applyingLimit(1000, to: "select 1 into @x").limited)
        #expect(!SQL.applyingLimit(1000, to: "update t set a = 1").limited)
        #expect(!SQL.applyingLimit(1000, to: "show tables").limited)
        #expect(!SQL.applyingLimit(nil, to: "select 1").limited)
        #expect(SQL.applyingLimit(10, to: "with x as (select 1) select * from x").limited)
    }

    @Test func tokenKinds() {
        let tokens = SQL.tokenize("SELECT `a`, 'b', 12, @v -- c").filter { $0.kind != .whitespace }
        #expect(tokens.map(\.kind) == [.keyword, .quotedIdentifier, .symbol, .string, .symbol, .number, .symbol, .variable, .comment])
    }

    @Test func beautifyUppercasesAndBreaksClauses() {
        let pretty = SQL.beautify("select a, b from t left join u on u.id = t.id where a = 1 order by b")
        #expect(pretty == "SELECT a, b\nFROM t\nLEFT JOIN u ON u.id = t.id\nWHERE a = 1\nORDER BY b")
    }

    @Test func quoting() {
        #expect(SQL.quoteIdentifier("we`ird") == "`we``ird`")
        #expect(SQL.quoteString("it's \\ ok") == "'it\\'s \\\\ ok'")
    }
}
