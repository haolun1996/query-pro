import Foundation
import Testing
@testable import SQCore

@Suite struct SQLDumpTests {
    /// The shape mysqldump writes, trimmed.
    let mysqldump = """
        -- MySQL dump 10.13  Distrib 8.0.36, for macos14 (arm64)
        --
        -- Host: localhost    Database: shop
        /*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
        /*!40101 SET NAMES utf8mb4 */;
        /*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;

        --
        -- Table structure for table `items`
        --

        DROP TABLE IF EXISTS `items`;
        /*!40101 SET @saved_cs_client     = @@character_set_client */;
        CREATE TABLE `items` (
          `id` int NOT NULL AUTO_INCREMENT,
          `name` varchar(50) DEFAULT NULL COMMENT 'a; b',
          PRIMARY KEY (`id`)
        ) ENGINE=InnoDB;

        LOCK TABLES `items` WRITE;
        /*!40000 ALTER TABLE `items` DISABLE KEYS */;
        INSERT INTO `items` VALUES (1,'semi; colon'),(2,'it\\'s'),(3,'-- not a comment');
        /*!40000 ALTER TABLE `items` ENABLE KEYS */;
        UNLOCK TABLES;
        DELIMITER ;;
        /*!50003 CREATE*/ /*!50003 TRIGGER `t` BEFORE INSERT ON `items` FOR EACH ROW BEGIN
          SET NEW.name = UPPER(NEW.name);
        END */;;
        DELIMITER ;
        /*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
        """

    @Test func splitsAMysqldumpFile() {
        let statements = SQLDump.statements(in: mysqldump)
        #expect(statements.map(\.kind) == [
            .setting, .setting, .setting,
            .other, .setting, .createTable,
            .transaction, .other, .data, .other, .transaction,
            .other,
            .setting,
        ])
        #expect(statements[0].text == "/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */")
        #expect(statements[3].line == 12)
        #expect(statements[5].text.hasSuffix("ENGINE=InnoDB"))
        #expect(statements[8].text == "INSERT INTO `items` VALUES (1,'semi; colon'),(2,'it\\'s'),(3,'-- not a comment')")
        // The trigger body keeps its own `;`: the delimiter was `;;`.
        #expect(statements[11].text.contains("SET NEW.name = UPPER(NEW.name);\nEND */"))
    }

    @Test func dataOnlyKeepsRowsAndSettings() {
        let plan = SQLDump.plan(SQLDump.statements(in: mysqldump), mode: .dataOnly)
        #expect(plan.statements.map(\.kind) == [.setting, .setting, .setting, .setting, .data, .setting])
        #expect(plan.skipped == 7)
        #expect(plan.dataStatements == 1)
        #expect(plan.tablesCreated == 0)

        let full = SQLDump.plan(SQLDump.statements(in: mysqldump), mode: .structureAndData)
        #expect(full.statements.count == 13)
        #expect(full.skipped == 0)
        #expect(full.tablesCreated == 1)
    }

    @Test func classifies() {
        #expect(SQLDump.kind(of: "insert ignore into t values (1)") == .data)
        #expect(SQLDump.kind(of: "REPLACE INTO t VALUES (1)") == .data)
        #expect(SQLDump.kind(of: "create temporary table t (a int)") == .createTable)
        #expect(SQLDump.kind(of: "CREATE DATABASE /*!32312 IF NOT EXISTS*/ `shop`") == .createSchema)
        #expect(SQLDump.kind(of: "CREATE VIEW v AS SELECT 1") == .other)
        #expect(SQLDump.kind(of: "SET autocommit=0") == .transaction)
        #expect(SQLDump.kind(of: "START TRANSACTION") == .transaction)
        #expect(SQLDump.kind(of: "USE `shop`") == .useSchema)
        #expect(SQLDump.kind(of: "DROP TABLE IF EXISTS `items`") == .other)
    }

    @Test func namesTheSchemasTheFileSwitchesTo() {
        let plan = SQLDump.plan(SQLDump.statements(in: "CREATE DATABASE shop; USE `shop`; INSERT INTO a VALUES (1); USE shop;"), mode: .dataOnly)
        #expect(plan.schemasNamed == ["shop"])
        #expect(!plan.createsSchemas)
        #expect(SQLDump.plan(SQLDump.statements(in: "CREATE DATABASE shop;"), mode: .structureAndData).createsSchemas)
    }

    @Test func otherDelimitersAndComments() {
        let text = """
            # hash comment; with a semicolon
            SELECT 1; /* block; comment */ SELECT 2
            delimiter $$
            CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END$$
            DELIMITER ;
            SELECT "a "" b;"
            """
        let statements = SQLDump.statements(in: text)
        #expect(statements.map(\.text) == [
            "SELECT 1",
            "SELECT 2",
            "CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END",
            #"SELECT "a "" b;""#,
        ])
        #expect(statements.map(\.line) == [2, 2, 4, 6])
    }

    @Test func emptyAndCommentOnlyFiles() {
        #expect(SQLDump.statements(in: "").isEmpty)
        #expect(SQLDump.statements(in: "-- nothing\n/* here */\n;;\n").isEmpty)
    }
}

@Suite struct TableScriptTests {
    @Test func dropAndTruncateTurnForeignKeyChecksOffAroundThem() {
        #expect(SchemaScript.dropTables(["a", "b`c"], in: "shop") == [
            "SET FOREIGN_KEY_CHECKS = 0",
            "DROP TABLE `shop`.`a`",
            "DROP TABLE `shop`.`b``c`",
            "SET FOREIGN_KEY_CHECKS = 1",
        ])
        #expect(SchemaScript.truncateTables(["a"], in: "shop") == [
            "SET FOREIGN_KEY_CHECKS = 0", "TRUNCATE TABLE `shop`.`a`", "SET FOREIGN_KEY_CHECKS = 1",
        ])
        #expect(SchemaScript.dropTables([], in: "shop").isEmpty)
    }
}
