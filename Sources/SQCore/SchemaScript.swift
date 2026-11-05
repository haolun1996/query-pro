import Foundation

/// The statements behind the schema tree's Alter / Drop Schemas… commands.
public enum SchemaScript {
    /// Schemas MySQL itself needs. Dropping `mysql` or `sys` breaks the server, so the app never offers it.
    public static func isSystem(_ schema: String) -> Bool {
        ConnectionProfile.systemSchemas.contains(schema.lowercased())
    }

    public static func drop(_ schemas: [String]) -> [String] {
        schemas.map { "DROP SCHEMA \(SQL.quoteIdentifier($0))" }
    }

    /// `nil` charset or collation leaves that part out. Only new tables use a schema's defaults.
    public static func alter(_ schemas: [String], charset: String?, collation: String?) -> [String] {
        var options: [String] = []
        if let charset, !charset.isEmpty { options.append("DEFAULT CHARACTER SET \(charset)") }
        if let collation, !collation.isEmpty { options.append("DEFAULT COLLATE \(collation)") }
        guard !options.isEmpty else { return [] }
        return schemas.map { "ALTER SCHEMA \(SQL.quoteIdentifier($0)) \(options.joined(separator: " "))" }
    }

    /// The statements as a script, one per line.
    public static func text(_ statements: [String]) -> String {
        statements.map { $0 + ";" }.joined(separator: "\n")
    }
}
