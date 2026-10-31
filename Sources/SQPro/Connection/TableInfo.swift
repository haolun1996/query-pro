import Foundation
import Observation

/// Everything the table info tab shows about one table or view.
@Observable
final class TableInfo {
    enum Section: String, CaseIterable, Identifiable {
        case columns = "Columns"
        case indexes = "Indexes"
        case foreignKeys = "Foreign Keys"
        case triggers = "Triggers"
        case ddl = "DDL"

        var id: Self { self }
    }

    struct Index: Identifiable {
        var id: String { name }
        let name: String
        let isUnique: Bool
        let type: String
        let columns: [String]
        let comment: String
    }

    struct ForeignKey: Identifiable {
        var id: String { name }
        let name: String
        let columns: [String]
        let referencedTable: String
        let referencedColumns: [String]
        let onUpdate: String
        let onDelete: String
    }

    struct Trigger: Identifiable {
        var id: String { name }
        let name: String
        /// e.g. "BEFORE INSERT"
        let timing: String
        let statement: String
    }

    struct Summary {
        var engine = ""
        var approximateRows = ""
        var collation = ""
        var autoIncrement = ""
        var dataSize = ""
        var comment = ""
    }

    let schema: String
    let table: String
    let isView: Bool
    var section = Section.columns
    var isLoading = false
    var error: String?

    var summary = Summary()
    var columns: [ColumnDetail] = []
    var indexes: [Index] = []
    var foreignKeys: [ForeignKey] = []
    var triggers: [Trigger] = []
    var ddl = ""

    init(schema: String, table: String, isView: Bool) {
        self.schema = schema
        self.table = table
        self.isView = isView
    }

    func count(of section: Section) -> Int? {
        switch section {
        case .columns: columns.count
        case .indexes: indexes.count
        case .foreignKeys: foreignKeys.count
        case .triggers: triggers.count
        case .ddl: nil
        }
    }
}
