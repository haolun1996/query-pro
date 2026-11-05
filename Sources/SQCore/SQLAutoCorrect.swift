import Foundation

/// A misspelled keyword and what replaces it, in UTF-16 offsets.
public struct SQLAutoCorrection: Sendable, Equatable {
    public var range: Range<Int>
    public var typed: String
    public var replacement: String
}

/// Fixes common misspellings of SQL keywords (`seelct` → `select`) when the user finishes a word.
///
/// A hand-picked list rather than edit distance: OR / ON / IN / IS are one letter apart, and turning a real name into
/// a keyword is worse than a typo MySQL reports. Words that could be names (`form`) are only fixed where a keyword
/// is the only sensible reading, and never when the loaded schema has a table, column or schema of that name.
public enum SQLAutoCorrect {
    enum Rule: Sendable {
        /// Never a name in practice.
        case anywhere
        /// `form`: after the select list (or DELETE), before the statement has a FROM.
        case fromClause
        /// `oder`: after an expression, once the statement has a FROM.
        case afterFrom
    }

    /// Lower-case typo → keyword. Every typo is at least 4 letters, isn't a keyword itself, and isn't an English word.
    static let typos: [String: (keyword: String, rule: Rule)] = {
        let anywhere: [String: [String]] = [
            "SELECT": ["seelct", "slect", "selct", "selet", "selec", "slecet", "sleect", "selcet", "eslect", "selecet"],
            "FROM": ["fomr", "frmo", "fron", "rfom", "fmor"],
            "WHERE": ["wehre", "whree", "wher", "whre", "hwere", "wheer", "wheree"],
            "INSERT": ["isnert", "insret", "inesrt", "insrt", "inser", "insetr"],
            "INTO": ["inot", "itno", "intot"],
            "UPDATE": ["udpate", "upadte", "updte", "upate", "updaet", "updtae", "updae"],
            "DELETE": ["delte", "deleet", "dleete", "delet", "dlete", "deelte"],
            "VALUES": ["vlaues", "valeus", "valuse", "vaules", "valuees"],
            "GROUP": ["gruop", "gorup", "grop", "grup", "groop"],
            "ORDER": ["odrer", "ordre", "oredr", "ordr"],
            "HAVING": ["haivng", "hvaing", "havign", "haveing", "havng"],
            "LIMIT": ["limt", "lmit", "limti", "liimt", "limmit"],
            "JOIN": ["jion", "joni"],
            "INNER": ["inenr", "innr", "innner"],
            "LEFT": ["lfet", "letf"],
            "RIGHT": ["rigth", "rihgt", "rgiht"],
            "DISTINCT": ["distnict", "disticnt", "distinc", "dsitinct", "distict"],
            "BETWEEN": ["bewteen", "betwen", "beetween", "betweeen"],
            "LIKE": ["liek", "lkie"],
            "SHOW": ["shwo", "sohw"],
            "TABLE": ["talbe", "tbale", "tabe"],
            "TABLES": ["talbes", "tabels", "tbales"],
            "DESCRIBE": ["decsribe", "descirbe", "desribe", "descibe"],
            "EXPLAIN": ["explian", "exlpain", "expalin"],
            "CREATE": ["craete", "creat", "cretae", "creaet"],
            "ALTER": ["alret", "atler", "altr"],
            "DROP": ["dorp", "drpo"],
            "TRUNCATE": ["trucnate", "truncte", "turncate"],
            "DATABASE": ["databse", "datbase", "dtabase", "databaes"],
            "DATABASES": ["databses", "datbases"],
            "EXISTS": ["exsits", "exsists", "exisits"],
            "UNION": ["unoin", "uinon", "unon"],
            "USING": ["usign", "uisng"],
            "OFFSET": ["ofset", "offest", "offsett"],
            "REPLACE": ["repalce", "replcae", "relpace"],
            "WHEN": ["wehn", "whne"],
            "THEN": ["tehn", "thne"],
            "ELSE": ["esle", "eles"],
            "TRANSACTION": ["transcation", "trasnaction", "transaciton", "transation"],
            "COMMIT": ["comit", "commti", "comitt"],
            "ROLLBACK": ["rolback", "rollbak", "rollbck"],
            "PRIMARY": ["primray", "pirmary", "primay"],
        ]
        var map: [String: (keyword: String, rule: Rule)] = [:]
        for (keyword, words) in anywhere {
            for word in words { map[word] = (keyword, .anywhere) }
        }
        map["form"] = ("FROM", .fromClause)
        map["oder"] = ("ORDER", .afterFrom)
        return map
    }()

    /// After these a name follows, so the word is never a keyword.
    private static let nameKeywords: Set<String> = [
        "FROM", "JOIN", "INTO", "UPDATE", "TABLE", "AS", "USE", "DATABASE", "SCHEMA", "VIEW", "INDEX", "COLUMN",
        "REFERENCES", "TRIGGER", "PROCEDURE", "FUNCTION", "DESCRIBE",
    ]

    /// `wordEnd` is where the word just finished: where the space, `(`, newline … was typed.
    /// `declined` holds lower-case typos the user has reverted; they're left alone from then on.
    public static func correction(
        in text: String, wordEnd: Int, catalog: CompletionCatalog? = nil, declined: Set<String> = []
    ) -> SQLAutoCorrection? {
        let utf16 = Array(text.utf16)
        guard wordEnd > 0, wordEnd <= utf16.count else { return nil }
        let tokens = SQL.tokenize(text)
        guard let index = tokens.firstIndex(where: { $0.range.upperBound == wordEnd }),
              tokens[index].kind == .identifier
        else { return nil }
        let word = tokens[index]
        func string(_ range: Range<Int>) -> String {
            String(utf16CodeUnits: Array(utf16[range]), count: range.count)
        }
        let typed = string(word.range)
        let key = typed.lowercased()
        guard let entry = typos[key], !declined.contains(key) else { return nil }

        // `t.limt` or `limt.x` is a qualified name.
        func isDot(_ i: Int) -> Bool { tokens.indices.contains(i) && tokens[i].kind == .symbol && string(tokens[i].range) == "." }
        if isDot(index - 1) || isDot(index + 1) { return nil }

        if let catalog, isName(key, in: catalog) { return nil }

        // The tokens before the word at its own nesting level, back to an unmatched `(`, a `;` or UNION. A closing
        // `)` stays in (so `count(*)` ends an expression); what's inside the parentheses doesn't.
        func upper(_ token: SQLToken) -> String { string(token.range).uppercased() }
        var level: [SQLToken] = []
        var depth = 0
        scan: for token in tokens[..<index].reversed() {
            switch token.kind {
            case .whitespace, .comment: continue
            case .semicolon: break scan
            case .openParen:
                if depth == 0 { break scan }
                depth -= 1
                continue
            case .closeParen:
                if depth == 0 { level.insert(token, at: 0) }
                depth += 1
                continue
            default: break
            }
            guard depth == 0 else { continue }
            if token.kind == .keyword, upper(token) == "UNION" { break scan }
            level.insert(token, at: 0)
        }
        let previous = level.last
        if let previous, previous.kind == .keyword, nameKeywords.contains(upper(previous)) { return nil }
        let hasFrom = level.contains { $0.kind == .keyword && upper($0) == "FROM" }
        // After a value or name: `id`, `'x'`, `1`, `count(*)`, `*`.
        let endsExpression: Bool = {
            guard let previous else { return false }
            switch previous.kind {
            case .identifier, .quotedIdentifier, .number, .string, .closeParen: return true
            case .symbol: return string(previous.range) == "*"
            default: return false
            }
        }()

        switch entry.rule {
        case .anywhere:
            break
        case .fromClause:
            // The last SELECT / DELETE, so `WITH … SELECT` and `INSERT … SELECT` count too.
            let verb = level.last { $0.kind == .keyword && ["SELECT", "DELETE"].contains(upper($0)) }
            guard !hasFrom, let verb, let previous else { return nil }
            if upper(verb) == "SELECT" {
                guard endsExpression else { return nil }
            } else {
                guard previous.range == verb.range else { return nil }
            }
        case .afterFrom:
            guard hasFrom, endsExpression else { return nil }
        }

        return SQLAutoCorrection(range: word.range, typed: typed, replacement: matchingCase(entry.keyword, typed: typed))
    }

    /// `seelct` → `select`, `SEELCT` → `SELECT`, `Seelct` → `Select`; anything else upper case.
    static func matchingCase(_ keyword: String, typed: String) -> String {
        if typed == typed.lowercased() { return keyword.lowercased() }
        if typed == typed.uppercased() { return keyword.uppercased() }
        let rest = typed.dropFirst()
        if typed.first?.isUppercase == true, rest == rest.lowercased() { return keyword.prefix(1) + keyword.dropFirst().lowercased() }
        return keyword.uppercased()
    }

    private static func isName(_ word: String, in catalog: CompletionCatalog) -> Bool {
        func same(_ name: String) -> Bool { name.caseInsensitiveCompare(word) == .orderedSame }
        if catalog.schemas.contains(where: same) { return true }
        return catalog.tables.values.contains { tables in
            tables.contains { table in same(table.name) || table.columns.contains { same($0.name) } }
        }
    }
}
