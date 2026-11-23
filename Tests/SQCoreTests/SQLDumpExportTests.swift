import Foundation
import Testing
@testable import SQCore

@Suite struct SQLDumpExportUnitTests {
    @Test func definersAreRemoved() {
        #expect(SQLDumpExport.withoutDefiner("CREATE DEFINER=`root`@`localhost` PROCEDURE `p`() SELECT 1")
            == "CREATE PROCEDURE `p`() SELECT 1")
        #expect(SQLDumpExport.withoutDefiner("CREATE ALGORITHM=UNDEFINED DEFINER=`a``b`@`%` SQL SECURITY DEFINER VIEW `v` AS select 1")
            == "CREATE ALGORITHM=UNDEFINED SQL SECURITY DEFINER VIEW `v` AS select 1")
    }

    @Test func viewsComeAfterTheViewsTheyUse() {
        let order = SQLDumpExport.orderViews([
            (name: "a_top", definition: "select * from `m_mid`"),
            (name: "m_mid", definition: "select * from `z_base`"),
            (name: "z_base", definition: "select * from `t`"),
        ])
        #expect(order == ["z_base", "m_mid", "a_top"])
    }

    @Test func emptyBinaryValuesAreEmptyStrings() {
        let blob = ColumnInfo(name: "b", schema: "", table: "", originalName: "b", typeName: "BLOB", isPrimaryKey: false, isNotNull: false, isBinary: true)
        #expect(SQLDumpExport.literal("0x", blob) == "''")
        #expect(SQLDumpExport.literal("0x00FF", blob) == "0x00FF")
        #expect(SQLDumpExport.literal(nil, blob) == "NULL")
    }
}

/// Export → import into another database → same checksums. Runs against the MySQL on localhost:3306 (root, no
/// password) in scratch databases; returns early without it unless SQPRO_REQUIRE_MYSQL is set.
@Suite(.serialized) struct SQLDumpExportTests {
    private func session(_ database: String = "") async -> MySQLSession? {
        var profile = ConnectionProfile(host: "127.0.0.1", user: "root")
        profile.defaultSchema = database
        let session = MySQLSession(profile: profile, password: "")
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

    private let fixture = """
        CREATE TABLE parent (id int PRIMARY KEY AUTO_INCREMENT, name varchar(40), data blob, note text, flag bit(1),
          amount decimal(10,2), created timestamp NULL, ratio double);
        CREATE TABLE child (id int PRIMARY KEY, parent_id int, qty int, total int AS (qty * 2) STORED,
          FOREIGN KEY (parent_id) REFERENCES parent (id));
        CREATE TABLE nopk (a int, b varchar(10));
        CREATE TABLE pairs (a int, b varchar(10), v varchar(20), PRIMARY KEY (a, b));
        INSERT INTO parent VALUES (0, 'zero', '', NULL, b'0', 0, NULL, NULL),
          (1, 'it''s "quoted" \\\\ back;slash', 0x00FF0A27, '', b'1', -12.50, '2024-03-01 10:00:00', 0.1),
          (2, 'ünïcode 😀', NULL, 'line\\nbreak', NULL, 99999999.99, '1999-12-31 23:59:59', 1e-300);
        INSERT INTO child (id, parent_id, qty) VALUES (1, 1, 3), (2, 2, 5);
        INSERT INTO nopk VALUES (1, 'x'), (1, 'x'), (NULL, NULL);
        INSERT INTO pairs VALUES (1, 'a', 'one'), (1, 'b', 'two'), (2, 'a', 'three'), (2, 'b', NULL), (3, '', 'five'),
          (3, 'z', 'six'), (4, 'a', 'seven');
        CREATE VIEW z_base AS SELECT id, name FROM parent;
        CREATE VIEW a_top AS SELECT id FROM z_base;
        CREATE TRIGGER child_qty BEFORE INSERT ON child FOR EACH ROW SET NEW.qty = IFNULL(NEW.qty, 0);
        DELIMITER $$
        CREATE PROCEDURE count_parents() BEGIN SELECT COUNT(*) FROM parent; SELECT 1; END$$
        DELIMITER ;
        CREATE FUNCTION twice(x int) RETURNS int DETERMINISTIC RETURN x * 2;
        """

    private func checksums(_ session: MySQLSession, _ database: String) async throws -> [String] {
        let q = SQL.quoteIdentifier(database)
        return try await session.execute("CHECKSUM TABLE \(q).parent, \(q).child, \(q).nopk, \(q).pairs").rows.map { $0[1] ?? "NULL" }
    }

    /// Drops the scratch databases before returning, even when the test fails. (A `defer { Task { … } }` would
    /// run too late: the test process can exit first and leave them behind.)
    @Test func roundTrip() async throws {
        let suffix = UInt32.random(in: 0...UInt32.max)
        let (source, copy) = ("sqpro_export_src_\(suffix)", "sqpro_export_copy_\(suffix)")
        guard let admin = await session() else { return }
        var failure: (any Error)?
        do {
            try await roundTrip(admin: admin, source: source, copy: copy, suffix: suffix)
        } catch {
            failure = error
        }
        for database in [source, copy] { _ = try? await admin.execute("DROP DATABASE IF EXISTS \(SQL.quoteIdentifier(database))") }
        await admin.close()
        if let failure { throw failure }
    }

    private func roundTrip(admin: MySQLSession, source: String, copy: String, suffix: UInt32) async throws {
        _ = try await admin.execute("CREATE DATABASE \(SQL.quoteIdentifier(source))")
        _ = try await admin.execute("CREATE DATABASE \(SQL.quoteIdentifier(copy))")
        let setup = try #require(await session(source))
        _ = try await setup.execute("SET SESSION sql_mode = CONCAT(@@sql_mode, ',NO_AUTO_VALUE_ON_ZERO')")
        for statement in SQLDump.statements(in: fixture) { _ = try await setup.execute(statement.text) }
        await setup.close()

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sqpro-export-\(suffix)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        func export(_ content: SQLDumpExport.Content, _ name: String) async throws -> (URL, SQLDumpExport.Outcome) {
            let url = folder.appendingPathComponent(name)
            let reader = try #require(await session())
            var options = SQLDumpExport.Options(content: content)
            // Tiny pages and INSERTs, so paging by a composite key and batching are both exercised.
            options.pageRows = 2
            options.insertBytes = 60
            let outcome = try await SQLDumpExport.run(schema: source, options: options, on: reader, to: url)
            await reader.close()
            return (url, outcome)
        }
        func importDump(_ url: URL, _ mode: SQLDump.Mode) async throws {
            let writer = try #require(await session())
            let plan = SQLDump.plan(SQLDump.statements(in: try String(contentsOf: url, encoding: .utf8)), mode: mode)
            _ = try await SQLDumpImport.run(plan, mode: mode, schema: copy, on: writer)
            await writer.close()
        }

        let (full, outcome) = try await export(.structureAndData, "full.sql")
        #expect(outcome.tables == 4)
        #expect(outcome.views == 2)
        #expect(outcome.routines == 2)
        #expect(outcome.triggers == 1)
        #expect(outcome.rows == 15)
        let text = try String(contentsOf: full, encoding: .utf8)
        #expect(!text.contains(SQL.quoteIdentifier(source)), "objects must not name the source schema")
        #expect(!text.contains("DEFINER=`"))
        #expect(text.range(of: "CREATE ALGORITHM")!.lowerBound > text.range(of: "CREATE TABLE `pairs`")!.lowerBound)
        #expect(text.range(of: "VIEW `z_base`")!.lowerBound < text.range(of: "VIEW `a_top`")!.lowerBound)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".partial") }
        #expect(leftovers.isEmpty)

        try await importDump(full, .structureAndData)
        let expected = try await checksums(admin, source)
        #expect(try await checksums(admin, copy) == expected)
        let objects = try await admin.execute("""
            SELECT (SELECT COUNT(*) FROM information_schema.VIEWS WHERE TABLE_SCHEMA = \(SQL.quoteString(copy))),
                   (SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = \(SQL.quoteString(copy))),
                   (SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = \(SQL.quoteString(copy)))
            """).rows.first
        #expect(objects == ["2", "2", "1"])

        // Data only into the emptied copy gives the same rows again. (The copy's triggers fire, so the fixture has
        // no row its trigger would change.)
        let (data, _) = try await export(.dataOnly, "data.sql")
        let dataText = try String(contentsOf: data, encoding: .utf8)
        #expect(!dataText.contains("CREATE TABLE"))
        #expect(!dataText.contains("TRIGGER"))
        let truncate = SchemaScript.truncateTables(["parent", "child", "nopk", "pairs"], in: copy)
        for statement in truncate { _ = try await admin.execute(statement) }
        try await importDump(data, .dataOnly)
        #expect(try await checksums(admin, copy) == expected)

        let (structure, structureOutcome) = try await export(.structureOnly, "structure.sql")
        #expect(structureOutcome.rows == 0)
        #expect(!(try String(contentsOf: structure, encoding: .utf8)).contains("INSERT INTO"))

        // A missing table fails without leaving a file.
        let reader = try #require(await session())
        let missing = folder.appendingPathComponent("missing.sql")
        await #expect(throws: SQLDumpExport.ExportError.self) {
            _ = try await SQLDumpExport.run(schema: source, options: .init(content: .structureAndData, tables: ["nope"]), on: reader, to: missing)
        }
        await reader.close()
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
}
