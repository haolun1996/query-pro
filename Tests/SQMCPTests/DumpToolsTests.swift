import Foundation
import MCP
import SQCore
import Testing
@testable import SQMCP

private struct RootProvider: MCPProvider {
    let saved: [ConnectionProfile]
    func profiles() async -> [ConnectionProfile] { saved }
    func password(for profile: ConnectionProfile) async -> String? { "" }
    func approveWrite(_ sql: String, on profile: ConnectionProfile) async -> Bool { false }
    func record(_ activity: MCPActivity) async {}
}

/// import_sql, truncate_tables and drop_tables against the MySQL on localhost:3306 (root, no password), in a
/// scratch database that is dropped afterwards. Returns early without that server unless SQPRO_REQUIRE_MYSQL is set.
@Suite(.serialized) struct DumpToolsTests {
    private let profile = ConnectionProfile(name: "Local", host: "127.0.0.1", user: "root", mcpAccess: .readWrite)

    /// Two tables where `lines` references `orders`, written child first so it only loads with FK checks off.
    private let dump = """
        DROP TABLE IF EXISTS `lines`;
        CREATE TABLE `lines` (id int PRIMARY KEY, order_id int, note varchar(20),
          FOREIGN KEY (order_id) REFERENCES orders (id));
        INSERT INTO `lines` VALUES (1, 1, 'a;b'), (2, 1, NULL);
        DROP TABLE IF EXISTS `orders`;
        CREATE TABLE `orders` (id int PRIMARY KEY AUTO_INCREMENT);
        INSERT INTO `orders` VALUES (1);
        DELIMITER ;;
        CREATE TRIGGER lines_upper BEFORE INSERT ON `lines` FOR EACH ROW BEGIN
          SET NEW.note = UPPER(NEW.note);
        END ;;
        DELIMITER ;
        """

    private func text(_ result: CallTool.Result) -> String {
        guard case .text(let text, _, _) = result.content.first else { return "" }
        return text
    }

    private func admin() async -> MySQLSession? {
        let session = MySQLSession(profile: ConnectionProfile(host: "127.0.0.1", user: "root"), password: "")
        do {
            try await session.connect()
            return session
        } catch {
            if ProcessInfo.processInfo.environment["SQPRO_REQUIRE_MYSQL"] != nil {
                Issue.record("Local MySQL (root, no password) is not reachable")
            }
            return nil
        }
    }

    /// Drops the scratch database before returning, even when the test fails.
    @Test func importTruncateReimportDrop() async throws {
        guard let admin = await admin() else { return }
        let database = "sqpro_dump_test_\(UInt32.random(in: 0...UInt32.max))"
        var failure: (any Error)?
        do {
            _ = try await admin.execute("CREATE DATABASE \(SQL.quoteIdentifier(database))")
            try await importTruncateReimportDrop(admin: admin, database: database)
        } catch {
            failure = error
        }
        _ = try? await admin.execute("DROP DATABASE IF EXISTS \(SQL.quoteIdentifier(database))")
        await admin.close()
        if let failure { throw failure }
    }

    private func importTruncateReimportDrop(admin: MySQLSession, database: String) async throws {
        let tools = SQLTools(provider: RootProvider(saved: [profile]), connection: profile.id)
        func count(_ table: String) async throws -> String? {
            try await admin.execute("SELECT COUNT(*) FROM \(SQL.quoteIdentifier(database)).\(SQL.quoteIdentifier(table))").rows.first?.first ?? nil
        }

        let imported = await tools.call("import_sql", arguments: ["mode": "structure_and_data", "database": .string(database), "sql": .string(dump)])
        #expect(imported.isError == false, "\(text(imported))")
        #expect(text(imported).contains(#""tables_created":2"#))
        #expect(try await count("lines") == "2")

        // Export works on read-only connections too, and won't replace a file unless asked.
        var readOnly = profile
        readOnly.mcpAccess = .readOnly
        let reader = SQLTools(provider: RootProvider(saved: [readOnly]), connection: readOnly.id)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(database).sql")
        defer { try? FileManager.default.removeItem(at: file) }
        let exportArguments: [String: Value] = ["database": .string(database), "content": "structure_and_data", "path": .string(file.path)]
        let exported = await reader.call("export_sql", arguments: exportArguments)
        #expect(exported.isError == false, "\(text(exported))")
        #expect(text(exported).contains(#""rows":3"#))
        #expect(text(exported).contains(#""triggers":1"#))
        #expect((try? String(contentsOf: file, encoding: .utf8))?.contains("INSERT INTO `orders`") == true)
        #expect(text(await reader.call("export_sql", arguments: exportArguments)).contains("already exists"))
        var replace = exportArguments
        replace["overwrite"] = true
        #expect(await reader.call("export_sql", arguments: replace).isError == false)

        let truncated = await tools.call("truncate_tables", arguments: ["database": .string(database)])
        #expect(truncated.isError == false, "\(text(truncated))")
        #expect(text(truncated).contains(#""truncated":["lines","orders"]"#))
        #expect(try await count("lines") == "0")

        // Data only: the DROP / CREATE are skipped, the rows go into the emptied tables, the trigger fires.
        let reloaded = await tools.call("import_sql", arguments: ["mode": "data_only", "database": .string(database), "sql": .string(dump)])
        #expect(reloaded.isError == false, "\(text(reloaded))")
        #expect(text(reloaded).contains(#""skipped":5"#))
        #expect(try await admin.execute("SELECT note FROM \(SQL.quoteIdentifier(database)).`lines` WHERE id = 1").rows.first?.first == "A;B")

        // A failing data-only import rolls everything back.
        let failing = await tools.call("import_sql", arguments: [
            "mode": "data_only", "database": .string(database),
            "sql": "INSERT INTO orders VALUES (5);\nINSERT INTO orders VALUES (1);",
        ])
        #expect(failing.isError == true)
        #expect(text(failing).contains("At line 2 (statement 2 of 2)"))
        #expect(text(failing).contains("Rolled back"))
        #expect(try await count("orders") == "1")

        let unknown = await tools.call("drop_tables", arguments: ["database": .string(database), "tables": ["orders", "nope"]])
        #expect(text(unknown).contains("No table nope"))

        let dropped = await tools.call("drop_tables", arguments: ["database": .string(database)])
        #expect(dropped.isError == false, "\(text(dropped))")
        let left = try await admin.execute(SchemaScript.tablesQuery(database)).rows
        #expect(left.isEmpty)
    }
}
