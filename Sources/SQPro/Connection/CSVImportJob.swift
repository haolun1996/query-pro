import Foundation
import Observation
import SQCore

/// One CSV import in progress: the parsed file, the column mapping and options, and how far it got.
@Observable
final class CSVImportJob: Identifiable {
    enum Phase: Equatable {
        case setup
        case running(done: Int, total: Int)
        case finished(String)
        case failed(String)
    }

    let id = UUID()
    let schema: String
    let table: String
    let columns: [ColumnDetail]
    let fileURL: URL
    @ObservationIgnored private let text: String

    var delimiter: Character {
        didSet { if delimiter != oldValue { Task { await reparse() } } }
    }
    var hasHeader = true {
        didSet { if hasHeader != oldValue { autoMap() } }
    }
    private(set) var rows: [[String?]] = []
    private(set) var isParsing = false
    /// For each CSV column, the table column it goes into (index into `columns`), or `nil` to skip it.
    var mapping: [Int?] = []
    var emptyIsNull = true
    var nullText = true
    var duplicates = CSVImportPlan.Duplicates.stop
    var phase = Phase.setup
    var isCancelled = false

    private init(schema: String, table: String, columns: [ColumnDetail], fileURL: URL, text: String) {
        self.schema = schema
        self.table = table
        self.columns = columns
        self.fileURL = fileURL
        self.text = text
        self.delimiter = CSV.detectDelimiter(text)
    }

    static func make(schema: String, table: String, columns: [ColumnDetail], fileURL: URL, text: String) async -> CSVImportJob {
        let job = CSVImportJob(schema: schema, table: table, columns: columns, fileURL: fileURL, text: text)
        await job.reparse()
        return job
    }

    private func reparse() async {
        isParsing = true
        let text = text
        let delimiter = delimiter
        rows = await Task.detached { CSV.parse(text, delimiter: delimiter) }.value
        isParsing = false
        autoMap()
    }

    /// By header name (ignoring case, spaces and punctuation) when the first row is a header, otherwise by position.
    private func autoMap() {
        var used = Set<Int>()
        mapping = (0..<csvColumnCount).map { index in
            let match: Int?
            if hasHeader {
                // "E-mail" or "Phone No" still find email / phone_no.
                let name = Self.simplified(headers[index])
                match = columns.firstIndex { $0.name.caseInsensitiveCompare(headers[index].trimmingCharacters(in: .whitespaces)) == .orderedSame }
                    ?? columns.firstIndex { Self.simplified($0.name) == name }
            } else {
                match = index < columns.count ? index : nil
            }
            guard let match, used.insert(match).inserted else { return nil }
            return match
        }
    }

    private static func simplified(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: Reading

    var csvColumnCount: Int {
        rows.prefix(100).map(\.count).max() ?? 0
    }

    /// Header names, or "Column 1", "Column 2", ….
    var headers: [String] {
        (0..<csvColumnCount).map { index in
            if hasHeader, let first = rows.first, index < first.count, let name = first[index], !name.isEmpty { return name }
            return "Column \(index + 1)"
        }
    }

    var dataRows: [[String?]] {
        hasHeader ? Array(rows.dropFirst()) : rows
    }

    /// The first few values of a CSV column, for the mapping list.
    func samples(_ column: Int) -> String {
        dataRows.prefix(3).map { row in
            guard column < row.count, let value = row[column] else { return "NULL" }
            return value.isEmpty ? "''" : value.split(whereSeparator: \.isNewline).joined(separator: " ↵ ")
        }.joined(separator: " · ")
    }

    var plan: CSVImportPlan {
        let targets = mapping.enumerated().compactMap { source, target -> CSVImportPlan.Target? in
            guard let target else { return nil }
            let type = columns[target].type.lowercased()
            return CSVImportPlan.Target(column: columns[target].name, source: source, isBinary: type.contains("blob") || type.contains("binary"))
        }
        var plan = CSVImportPlan(schema: schema, table: table, targets: targets)
        plan.emptyIsNull = emptyIsNull
        plan.nullText = nullText
        plan.duplicates = duplicates
        return plan
    }

    /// Why Import is disabled, if it is.
    var problem: String? {
        if isParsing { return "Reading the file…" }
        if dataRows.isEmpty { return "The file has no rows to import." }
        let targets = mapping.compactMap { $0 }
        if targets.isEmpty { return "Choose at least one table column." }
        if Set(targets).count != targets.count { return "Each table column can only take one CSV column." }
        return nil
    }

    /// Table columns that get nothing and have no default, so MySQL may reject the rows.
    var unfilledRequiredColumns: [String] {
        let filled = Set(mapping.compactMap { $0 })
        return columns.indices.filter { index in
            let column = columns[index]
            return !filled.contains(index) && !column.isNullable && column.defaultValue == nil && !column.extra.lowercased().contains("auto_increment")
                && !column.extra.uppercased().contains("GENERATED")
        }.map { columns[$0].name }
    }
}
