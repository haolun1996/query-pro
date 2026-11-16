import Foundation

/// The statements behind the schema tree's Alter / Drop Schemas… and Drop / Truncate Tables… commands.
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

    /// The base tables of a schema (no views), with InnoDB's row estimate: what "all tables" means.
    public static func tablesQuery(_ schema: String) -> String {
        """
        SELECT TABLE_NAME, TABLE_ROWS FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = \(SQL.quoteString(schema)) AND TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_NAME
        """
    }

    /// One `DROP TABLE` per table, so a failure names the table. Foreign key checks are off around them:
    /// tables that reference each other can't be dropped in any order otherwise.
    public static func dropTables(_ tables: [String], in schema: String) -> [String] {
        withoutForeignKeyChecks(tables.map { "DROP TABLE \(SQL.quoteIdentifier(schema)).\(SQL.quoteIdentifier($0))" })
    }

    /// Empties the tables and resets AUTO_INCREMENT. InnoDB refuses to truncate a table another table
    /// references unless foreign key checks are off.
    public static func truncateTables(_ tables: [String], in schema: String) -> [String] {
        withoutForeignKeyChecks(tables.map { "TRUNCATE TABLE \(SQL.quoteIdentifier(schema)).\(SQL.quoteIdentifier($0))" })
    }

    public static let foreignKeyChecksOff = "SET FOREIGN_KEY_CHECKS = 0"
    public static let foreignKeyChecksOn = "SET FOREIGN_KEY_CHECKS = 1"

    private static func withoutForeignKeyChecks(_ statements: [String]) -> [String] {
        statements.isEmpty ? [] : [foreignKeyChecksOff] + statements + [foreignKeyChecksOn]
    }

    /// The statements as a script, one per line.
    public static func text(_ statements: [String]) -> String {
        statements.map { $0 + ";" }.joined(separator: "\n")
    }
}
