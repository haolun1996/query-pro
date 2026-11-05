import Foundation
import Testing
@testable import SQCore

@Suite struct SQLAutoCorrectTests {
    /// `|` marks where the boundary (space, `(` …) was typed: the word before it is checked.
    /// Returns the text after the correction, or `nil` when nothing changes.
    private func fix(_ text: String, catalog: CompletionCatalog? = nil, declined: Set<String> = []) -> String? {
        let end = (text as NSString).range(of: "|").location
        let sql = text.replacingOccurrences(of: "|", with: "")
        guard let correction = SQLAutoCorrect.correction(in: sql, wordEnd: end, catalog: catalog, declined: declined) else { return nil }
        #expect((sql as NSString).substring(with: NSRange(location: correction.range.lowerBound, length: correction.range.count)) == correction.typed)
        return (sql as NSString).replacingCharacters(
            in: NSRange(location: correction.range.lowerBound, length: correction.range.count), with: correction.replacement
        )
    }

    @Test func listIsSafe() {
        for (typo, entry) in SQLAutoCorrect.typos {
            #expect(typo.count >= 4, "\(typo) is too short to guess")
            #expect(typo == typo.lowercased())
            #expect(!SQL.keywords.contains(typo.uppercased()), "\(typo) is a keyword")
            #expect(SQL.keywords.contains(entry.keyword), "\(entry.keyword) isn't highlighted as a keyword")
        }
    }

    @Test func commonTypos() {
        #expect(fix("seelct| ") == "select ")
        #expect(fix("select * fomr| ") == "select * from ")
        #expect(fix("select * from t wehre| ") == "select * from t where ")
        #expect(fix("udpate| t set a = 1") == "update t set a = 1")
        #expect(fix("insert inot| t") == "insert into t")
        #expect(fix("select a, count(*) from t gruop| ") == "select a, count(*) from t group ")
        #expect(fix("select * from t order by id desc limt| ") == "select * from t order by id desc limit ")
        #expect(fix("insert into t vlaues|(") == "insert into t values(")
        #expect(fix("select 1;\nseelct|") == "select 1;\nselect")
    }

    @Test func keepsTheTypedCase() {
        #expect(fix("SEELCT| ") == "SELECT ")
        #expect(fix("Seelct| ") == "Select ")
        #expect(fix("sEElct| ") == "SELECT ")
    }

    @Test func leavesNamesAlone() {
        #expect(fix("select t.limt| ") == nil)
        #expect(fix("select limt|.a") == nil)
        #expect(fix("select * from talbes| ") == nil, "a table name goes after FROM")
        #expect(fix("select a as limt| ") == nil)
        #expect(fix("select `seelct`| ") == nil)
        #expect(fix("select 'seelct'| ") == nil)
        #expect(fix("-- seelct| ") == nil)
        #expect(fix("select from| ") == nil, "already a keyword")
        #expect(fix("select seelctx| ") == nil)
    }

    @Test func skipsNamesInTheSchema() {
        let catalog = CompletionCatalog(
            schemas: ["pos"], currentSchema: "pos",
            tables: ["pos": [.init(name: "forms", columns: [.init(name: "form", type: "int"), .init(name: "Limt", type: "int")])]]
        )
        #expect(fix("select * form| ", catalog: catalog) == nil)
        #expect(fix("select limt| ", catalog: catalog) == nil)
        #expect(fix("seelct| ", catalog: catalog) == "select ")
    }

    @Test func formOnlyWhereFromBelongs() {
        #expect(fix("select * form| ") == "select * from ")
        #expect(fix("select id, name form| ") == "select id, name from ")
        #expect(fix("select count(*) form| ") == "select count(*) from ")
        #expect(fix("delete form| ") == "delete from ")
        #expect(fix("select a from t where b in (select b form| ") == "select a from t where b in (select b from ")
        #expect(fix("select a from t union select b form| ") == "select a from t union select b from ")

        #expect(fix("select form| ") == nil, "a column named form")
        #expect(fix("select id, form| ") == nil)
        #expect(fix("select distinct form| ") == nil)
        #expect(fix("select a from t form| ") == nil, "already has FROM: an alias")
        #expect(fix("select * from form| ") == nil)
        #expect(fix("update t set form| ") == nil)
        #expect(fix("form| ") == nil)
    }

    @Test func oderOnlyAfterFrom() {
        #expect(fix("select * from t oder| ") == "select * from t order ")
        #expect(fix("select * from t where a = 1 oder| ") == "select * from t where a = 1 order ")
        #expect(fix("select oder| ") == nil)
        #expect(fix("select * from t where oder| ") == nil)
    }

    @Test func declinedTyposStay() {
        #expect(fix("seelct| ", declined: ["seelct"]) == nil)
        #expect(fix("SEELCT| ", declined: ["seelct"]) == nil)
    }
}
