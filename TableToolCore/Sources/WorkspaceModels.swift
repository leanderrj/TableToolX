import Foundation

public struct WorkspaceColumn: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64
    public var ordinal: Int
    public var name: String

    public init(id: Int64, ordinal: Int, name: String) {
        self.id = id
        self.ordinal = ordinal
        self.name = name
    }
}

public struct WorkspaceRow: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var values: [String]

    public init(id: Int64, values: [String]) {
        self.id = id
        self.values = values
    }
}

public struct WorkspaceRowSnapshot: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var orderKey: Int64
    public var values: [String]

    public init(id: Int64, orderKey: Int64, values: [String]) {
        self.id = id
        self.orderKey = orderKey
        self.values = values
    }
}

public struct WorkspaceRowBatchSnapshot: Equatable, Sendable {
    public var storageID: String
    public var count: Int64

    public init(storageID: String, count: Int64) {
        self.storageID = storageID
        self.count = count
    }
}

public struct WorkspaceCellSnapshot: Equatable, Sendable {
    public var rowID: Int64
    public var value: String

    public init(rowID: Int64, value: String) {
        self.rowID = rowID
        self.value = value
    }
}

public struct WorkspaceColumnSnapshot: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var ordinal: Int
    public var name: String
    public var cells: [WorkspaceCellSnapshot]
    public var storageID: String?

    public init(id: Int64, ordinal: Int, name: String, cells: [WorkspaceCellSnapshot], storageID: String? = nil) {
        self.id = id
        self.ordinal = ordinal
        self.name = name
        self.cells = cells
        self.storageID = storageID
    }
}

public struct WorkspacePasteSnapshot: Equatable, Sendable {
    public var rows: [WorkspaceRowSnapshot]
    public var columns: [WorkspaceColumn]

    public init(rows: [WorkspaceRowSnapshot], columns: [WorkspaceColumn]) {
        self.rows = rows
        self.columns = columns
    }
}

public struct WorkspaceReplacementResult: Equatable, Sendable {
    public var replacementCount: Int64
    public var snapshotID: String?

    public init(replacementCount: Int64, snapshotID: String?) {
        self.replacementCount = replacementCount
        self.snapshotID = snapshotID
    }
}

public struct GridPage: Equatable, Sendable {
    public var offset: Int64
    public var rows: [WorkspaceRow]
    public var totalRowCount: Int64

    public init(offset: Int64, rows: [WorkspaceRow], totalRowCount: Int64) {
        self.offset = offset
        self.rows = rows
        self.totalRowCount = totalRowCount
    }
}

public struct WorkspaceImportProgress: Sendable {
    public var bytesRead: Int64
    public var totalBytes: Int64
    public var rowsImported: Int64
    public var previewRows: [WorkspaceRow]
    public var header: [String]?
    public var maximumColumnCount: Int

    public init(
        bytesRead: Int64,
        totalBytes: Int64,
        rowsImported: Int64,
        previewRows: [WorkspaceRow] = [],
        header: [String]? = nil,
        maximumColumnCount: Int = 0
    ) {
        self.bytesRead = bytesRead
        self.totalBytes = totalBytes
        self.rowsImported = rowsImported
        self.previewRows = previewRows
        self.header = header
        self.maximumColumnCount = maximumColumnCount
    }
}

public enum ColumnComparison: String, Codable, Sendable {
    case text
    case number
    case date
}

public enum FilterOperator: String, Codable, Sendable {
    case contains, doesNotContain, equals, notEqual, prefix, suffix, regex
    case lessThan, lessThanOrEqual, greaterThan, greaterThanOrEqual, between
    case isEmpty, isNotEmpty
}

public struct FilterRule: Codable, Equatable, Sendable {
    public var columnID: Int64
    public var comparison: ColumnComparison
    public var operation: FilterOperator
    public var value: String
    public var secondValue: String?
    public var caseSensitive: Bool

    public init(columnID: Int64, comparison: ColumnComparison = .text, operation: FilterOperator, value: String = "", secondValue: String? = nil, caseSensitive: Bool = false) {
        self.columnID = columnID
        self.comparison = comparison
        self.operation = operation
        self.value = value
        self.secondValue = secondValue
        self.caseSensitive = caseSensitive
    }
}

public struct SortRule: Codable, Equatable, Sendable {
    public var columnID: Int64
    public var comparison: ColumnComparison
    public var ascending: Bool

    public init(columnID: Int64, comparison: ColumnComparison = .text, ascending: Bool = true) {
        self.columnID = columnID
        self.comparison = comparison
        self.ascending = ascending
    }
}

public struct ViewDefinition: Codable, Equatable, Sendable {
    public var filters: [FilterRule]
    public var sorts: [SortRule]

    public init(filters: [FilterRule] = [], sorts: [SortRule] = []) {
        self.filters = filters
        self.sorts = sorts
    }

    public static let documentOrder = ViewDefinition()
}

public struct SearchOptions: Sendable {
    public var caseSensitive: Bool
    public var regularExpression: Bool
    public var columnOrdinals: Set<Int>?

    public init(caseSensitive: Bool = false, regularExpression: Bool = false, columnOrdinals: Set<Int>? = nil) {
        self.caseSensitive = caseSensitive
        self.regularExpression = regularExpression
        self.columnOrdinals = columnOrdinals
    }
}

public struct SearchMatch: Equatable, Sendable {
    public var rowID: Int64
    public var columnOrdinal: Int
    public var range: Range<String.Index>?

    public init(rowID: Int64, columnOrdinal: Int, range: Range<String.Index>? = nil) {
        self.rowID = rowID
        self.columnOrdinal = columnOrdinal
        self.range = range
    }
}
