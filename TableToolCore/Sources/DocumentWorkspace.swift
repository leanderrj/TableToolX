import Foundation
import SQLite3

public actor DocumentWorkspace {
    private enum ViewBinding {
        case text(String)
        case number(Double)
    }

    public let databaseURL: URL
    private let db: SQLiteConnection
    private var dialect: CSVDialect = .standard
    private var activeView = false
    private var activeViewDefinition: ViewDefinition = .documentOrder
    private var documentPageCursors: [Int64: Int64] = [:]
    private var documentPageCursorOffsets: [Int64] = []
    private let maximumDocumentPageCursors = 128

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        db = try SQLiteConnection(url: databaseURL)
        try db.execute(Self.schema)
        let statement = try db.prepare("SELECT value FROM metadata WHERE key='dialect'")
        defer { sqlite3_finalize(statement) }
        if sqlite3_step(statement) == SQLITE_ROW,
           let text = sqlite3_column_text(statement, 0),
           let data = String(cString: text).data(using: .utf8),
           let stored = try? JSONDecoder().decode(CSVDialect.self, from: data) {
            dialect = stored
        }
        let viewStatement = try db.prepare("SELECT EXISTS(SELECT 1 FROM view_rows LIMIT 1)")
        defer { sqlite3_finalize(viewStatement) }
        if sqlite3_step(viewStatement) == SQLITE_ROW { activeView = sqlite3_column_int(viewStatement, 0) != 0 }
        if activeView {
            let definitionStatement = try db.prepare("SELECT value FROM metadata WHERE key='viewDefinition'")
            defer { sqlite3_finalize(definitionStatement) }
            if sqlite3_step(definitionStatement) == SQLITE_ROW,
               let text = sqlite3_column_text(definitionStatement, 0),
               let data = String(cString: text).data(using: .utf8),
               let stored = try? JSONDecoder().decode(ViewDefinition.self, from: data) {
                activeViewDefinition = stored
            } else {
                try db.execute("DELETE FROM view_rows")
                activeView = false
            }
        }
    }

    public static func temporaryURL(identifier: UUID = UUID()) throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TableToolX/Workspaces", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try? mutableRoot.setResourceValues(values)
        return root.appendingPathComponent(identifier.uuidString).appendingPathExtension("sqlite")
    }

    public func currentDialect() -> CSVDialect { dialect }

    public func currentViewDefinition() -> ViewDefinition { activeViewDefinition }

    public func hasActiveView() -> Bool { activeView }

    public func updateDialect(_ dialect: CSVDialect) throws {
        try storeDialect(dialect)
    }

    public func restoreExisting() throws -> GridPage {
        try page(offset: 0)
    }

    public func initializeNewDocument(columns count: Int = 3) throws {
        try reset()
        try ensureColumnCount(count, suggestedNames: (0..<count).map { "Column \($0 + 1)" })
        try insert(values: Array(repeating: "", count: count), orderKey: 1_024)
        try storeDialect(.standard)
    }

    public func importCSV(
        from sourceURL: URL,
        dialect: CSVDialect,
        recoveryPolicy: CSVRecoveryPolicy = .strict,
        progress: (@Sendable (WorkspaceImportProgress) -> Void)? = nil
    ) throws -> WorkspaceImportResult {
        try reset()
        try storeDialect(dialect)
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let totalBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let parser = try CSVStreamParser(dialect: dialect, recoveryPolicy: recoveryPolicy)
        let accumulator = try CSVImportAccumulator(database: db, dialect: dialect)

        try db.execute("BEGIN IMMEDIATE")
        do {
            try parser.parse(fileURL: sourceURL, progress: { bytes in
                progress?(accumulator.progress(bytesRead: bytes, totalBytes: totalBytes))
            }) { record in
                try accumulator.consume(record)
            }
            try ensureColumnCount(max(accumulator.maximumColumns, 1), suggestedNames: accumulator.header ?? [])
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
        // Bulk imports can leave a WAL as large as the workspace even after every page has
        // been checkpointed. Truncating it here avoids temporarily requiring roughly twice
        // the document's indexed size on disk while the document remains open.
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        progress?(accumulator.progress(bytesRead: totalBytes, totalBytes: totalBytes))
        return WorkspaceImportResult(
            diagnostics: parser.diagnostics,
            totalDiagnosticCount: parser.totalDiagnosticCount
        )
    }

    public func columns() throws -> [WorkspaceColumn] {
        let statement = try db.prepare("SELECT id, ordinal, name FROM columns ORDER BY ordinal")
        defer { sqlite3_finalize(statement) }
        var result: [WorkspaceColumn] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let nameLength = Int(sqlite3_column_bytes(statement, 2))
            let name = nameLength == 0
                ? ""
                : String(decoding: UnsafeBufferPointer(
                    start: sqlite3_column_text(statement, 2),
                    count: nameLength
                ), as: UTF8.self)
            result.append(WorkspaceColumn(
                id: sqlite3_column_int64(statement, 0),
                ordinal: Int(sqlite3_column_int64(statement, 1)),
                name: name
            ))
        }
        return result
    }

    public func rowCount() throws -> Int64 {
        let sql = activeView ? "SELECT COUNT(*) FROM view_rows" : "SELECT COUNT(*) FROM rows"
        let statement = try db.prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    public func page(offset: Int64, limit: Int = 256) throws -> GridPage {
        let sql: String
        if activeView {
            sql = "SELECT r.id, r.payload FROM view_rows v JOIN rows r ON r.id=v.row_id WHERE v.position>=? ORDER BY v.position LIMIT ?"
        } else if offset == 0 {
            sql = "SELECT id,order_key,payload FROM rows ORDER BY order_key LIMIT ?"
        } else if documentPageCursors[offset] != nil {
            sql = "SELECT id,order_key,payload FROM rows WHERE order_key>=? ORDER BY order_key LIMIT ?"
        } else {
            sql = "SELECT id,order_key,payload FROM rows ORDER BY order_key LIMIT ? OFFSET ?"
        }
        let statement = try db.prepare(sql)
        defer { sqlite3_finalize(statement) }
        if activeView {
            db.bind(offset, at: 1, to: statement)
            db.bind(Int64(limit), at: 2, to: statement)
        } else if offset == 0 {
            db.bind(Int64(limit), at: 1, to: statement)
        } else if let cursor = documentPageCursors[offset] {
            db.bind(cursor, at: 1, to: statement)
            db.bind(Int64(limit), at: 2, to: statement)
        } else {
            db.bind(Int64(limit), at: 1, to: statement)
            db.bind(offset, at: 2, to: statement)
        }
        var rows: [WorkspaceRow] = []
        var firstOrderKey: Int64?
        var lastOrderKey: Int64?
        while sqlite3_step(statement) == SQLITE_ROW {
            let payloadColumn: Int32 = activeView ? 1 : 2
            if !activeView {
                let orderKey = sqlite3_column_int64(statement, 1)
                firstOrderKey = firstOrderKey ?? orderKey
                lastOrderKey = orderKey
            }
            let length = Int(sqlite3_column_bytes(statement, payloadColumn))
            let data = Data(bytes: sqlite3_column_blob(statement, payloadColumn), count: length)
            rows.append(WorkspaceRow(id: sqlite3_column_int64(statement, 0), values: try PackedRowCodec.decode(data)))
        }
        if !activeView {
            if let firstOrderKey { storeDocumentPageCursor(firstOrderKey, at: offset) }
            if let lastOrderKey, !rows.isEmpty, lastOrderKey < Int64.max {
                storeDocumentPageCursor(lastOrderKey + 1, at: offset + Int64(rows.count))
            }
        }
        return GridPage(offset: offset, rows: rows, totalRowCount: try rowCount())
    }

    public func rows(inVisibleRanges ranges: [Range<Int64>]) throws -> [WorkspaceRow] {
        try Task.checkCancellation()
        var result: [WorkspaceRow] = []
        var processed = 0
        for range in ranges where !range.isEmpty {
            let sql: String
            if activeView {
                sql = "SELECT r.id,r.payload FROM view_rows v JOIN rows r ON r.id=v.row_id WHERE v.position>=? AND v.position<? ORDER BY v.position"
            } else {
                sql = "SELECT id,payload FROM rows ORDER BY order_key LIMIT ? OFFSET ?"
            }
            let statement = try db.prepare(sql)
            if activeView {
                db.bind(range.lowerBound, at: 1, to: statement)
                db.bind(range.upperBound, at: 2, to: statement)
            } else {
                db.bind(Int64(range.count), at: 1, to: statement)
                db.bind(range.lowerBound, at: 2, to: statement)
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                if processed.isMultiple(of: 1_000) { try Task.checkCancellation() }
                let data = Data(bytes: sqlite3_column_blob(statement, 1), count: Int(sqlite3_column_bytes(statement, 1)))
                result.append(WorkspaceRow(id: sqlite3_column_int64(statement, 0), values: try PackedRowCodec.decode(data)))
                processed += 1
            }
            sqlite3_finalize(statement)
        }
        return result
    }

    public func visibleIndex(ofRowID rowID: Int64) throws -> Int64? {
        let sql = activeView
            ? "SELECT position FROM view_rows WHERE row_id=?"
            : "SELECT (SELECT COUNT(*) FROM rows preceding WHERE preceding.order_key < target.order_key) FROM rows target WHERE target.id=?"
        let statement = try db.prepare(sql)
        defer { sqlite3_finalize(statement) }
        db.bind(rowID, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    public func updateCell(rowID: Int64, columnOrdinal: Int, value: String) throws -> String {
        var values = try values(for: rowID)
        while values.count <= columnOrdinal { values.append("") }
        let previous = values[columnOrdinal]
        values[columnOrdinal] = value
        let columnID = try columnID(at: columnOrdinal)
        let projectedColumn = try builtProjectionColumns().first { $0.ordinal == columnOrdinal }
        let statement = try db.prepare("UPDATE rows SET payload=? WHERE id=?")
        defer { sqlite3_finalize(statement) }
        try db.execute("BEGIN IMMEDIATE")
        do {
            db.bind(PackedRowCodec.encode(values), at: 1, to: statement)
            db.bind(rowID, at: 2, to: statement)
            try db.stepDone(statement)
            if let projectedColumn {
                try writeProjections(for: [(rowID: rowID, values: values)], columns: [projectedColumn])
            }
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
        if let columnID, activeViewReferences(columnID: columnID) {
            try refreshActiveView()
        }
        return previous
    }

    public func renameColumn(id: Int64, name: String) throws {
        let statement = try db.prepare("UPDATE columns SET name=? WHERE id=?")
        defer { sqlite3_finalize(statement) }
        db.bind(name, at: 1, to: statement)
        db.bind(id, at: 2, to: statement)
        try db.stepDone(statement)
    }

    public func reorderColumns(ids: [Int64]) throws {
        try Task.checkCancellation()
        let existing = try columns()
        guard ids.count == existing.count, Set(ids) == Set(existing.map(\.id)) else {
            throw SQLiteFailure.message("The requested column order does not match this document.")
        }
        guard ids != existing.map(\.id) else { return }

        let oldOrdinalByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0.ordinal) })
        let select = try db.prepare("SELECT id,payload FROM rows")
        defer { sqlite3_finalize(select) }
        let updateRow = try db.prepare("UPDATE rows SET payload=? WHERE id=?")
        defer { sqlite3_finalize(updateRow) }
        let updateColumn = try db.prepare("UPDATE columns SET ordinal=? WHERE id=?")
        defer { sqlite3_finalize(updateColumn) }

        try db.execute("BEGIN IMMEDIATE")
        do {
            var processed = 0
            while sqlite3_step(select) == SQLITE_ROW {
                if processed.isMultiple(of: 1_000) { try Task.checkCancellation() }
                let rowID = sqlite3_column_int64(select, 0)
                let data = Data(bytes: sqlite3_column_blob(select, 1), count: Int(sqlite3_column_bytes(select, 1)))
                let values = try PackedRowCodec.decode(data)
                let reordered = ids.map { id -> String in
                    guard let oldOrdinal = oldOrdinalByID[id], oldOrdinal < values.count else { return "" }
                    return values[oldOrdinal]
                }
                sqlite3_reset(updateRow)
                sqlite3_clear_bindings(updateRow)
                db.bind(PackedRowCodec.encode(reordered), at: 1, to: updateRow)
                db.bind(rowID, at: 2, to: updateRow)
                try db.stepDone(updateRow)
                processed += 1
            }
            try Task.checkCancellation()
            for (newOrdinal, id) in ids.enumerated() {
                sqlite3_reset(updateColumn)
                sqlite3_clear_bindings(updateColumn)
                db.bind(Int64(-(newOrdinal + 1)), at: 1, to: updateColumn)
                db.bind(id, at: 2, to: updateColumn)
                try db.stepDone(updateColumn)
            }
            try Task.checkCancellation()
            try db.execute("UPDATE columns SET ordinal=(-ordinal)-1 WHERE ordinal<0; DELETE FROM projections; DELETE FROM projected_columns; COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
        try refreshActiveView()
    }

    @discardableResult
    public func appendColumn(name: String? = nil) throws -> WorkspaceColumn {
        try insertColumn(at: columns().count, name: name)
    }

    @discardableResult
    public func insertColumn(at ordinal: Int, name: String? = nil) throws -> WorkspaceColumn {
        try insertColumn(at: ordinal, name: name, id: nil, cellValues: [:])
    }

    public func duplicateColumn(id: Int64) throws -> WorkspaceColumn {
        let existing = try columns()
        guard let source = existing.first(where: { $0.id == id }) else { throw SQLiteFailure.message("The column no longer exists.") }
        return try insertColumn(
            at: source.ordinal + 1,
            name: source.name + " Copy",
            id: nil,
            cellValues: [:],
            copyingOrdinal: source.ordinal
        )
    }

    @discardableResult
    public func deleteColumn(id: Int64) throws -> WorkspaceColumnSnapshot {
        try Task.checkCancellation()
        let existing = try columns()
        guard existing.count > 1, let removed = existing.first(where: { $0.id == id }) else {
            throw SQLiteFailure.message("A document must retain at least one column.")
        }
        let select = try db.prepare("SELECT id,payload FROM rows")
        defer { sqlite3_finalize(select) }
        let update = try db.prepare("UPDATE rows SET payload=? WHERE id=?")
        defer { sqlite3_finalize(update) }
        let storageID = UUID().uuidString
        let storeCell = try db.prepare("INSERT INTO column_snapshot_cells(snapshot_id,row_id,value) VALUES(?,?,?)")
        defer { sqlite3_finalize(storeCell) }
        try db.execute("BEGIN IMMEDIATE")
        do {
            var processed = 0
            while sqlite3_step(select) == SQLITE_ROW {
                if processed.isMultiple(of: 1_000) { try Task.checkCancellation() }
                let rowID = sqlite3_column_int64(select, 0)
                let data = Data(bytes: sqlite3_column_blob(select, 1), count: Int(sqlite3_column_bytes(select, 1)))
                var values = try PackedRowCodec.decode(data)
                let value = removed.ordinal < values.count ? values[removed.ordinal] : ""
                sqlite3_reset(storeCell); sqlite3_clear_bindings(storeCell)
                db.bind(storageID, at: 1, to: storeCell); db.bind(rowID, at: 2, to: storeCell)
                db.bind(Data(value.utf8), at: 3, to: storeCell); try db.stepDone(storeCell)
                if removed.ordinal < values.count { values.remove(at: removed.ordinal) }
                sqlite3_reset(update); sqlite3_clear_bindings(update)
                db.bind(PackedRowCodec.encode(values), at: 1, to: update); db.bind(rowID, at: 2, to: update)
                try db.stepDone(update)
                processed += 1
            }
            let delete = try db.prepare("DELETE FROM columns WHERE id=?")
            db.bind(id, at: 1, to: delete); try db.stepDone(delete); sqlite3_finalize(delete)
            try db.execute("UPDATE columns SET ordinal=-(ordinal+1)")
            let updateOrdinal = try db.prepare("UPDATE columns SET ordinal=? WHERE id=?")
            for (newOrdinal, column) in existing.filter({ $0.id != id }).enumerated() {
                sqlite3_reset(updateOrdinal); sqlite3_clear_bindings(updateOrdinal)
                db.bind(Int64(newOrdinal), at: 1, to: updateOrdinal); db.bind(column.id, at: 2, to: updateOrdinal)
                try db.stepDone(updateOrdinal)
            }
            sqlite3_finalize(updateOrdinal)
            try db.execute("DELETE FROM projections; DELETE FROM projected_columns; COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
        activeViewDefinition.filters.removeAll { $0.columnID == id }
        activeViewDefinition.sorts.removeAll { $0.columnID == id }
        try refreshActiveView()
        return WorkspaceColumnSnapshot(id: removed.id, ordinal: removed.ordinal, name: removed.name, cells: [], storageID: storageID)
    }

    @discardableResult
    public func restoreColumn(_ column: WorkspaceColumnSnapshot) throws -> WorkspaceColumn {
        let values = Dictionary(uniqueKeysWithValues: column.cells.map { ($0.rowID, $0.value) })
        return try insertColumn(
            at: column.ordinal,
            name: column.name,
            id: column.id,
            cellValues: values,
            snapshotStorageID: column.storageID
        )
    }

    @discardableResult
    public func deleteColumns(ids: [Int64]) throws -> [WorkspaceColumnSnapshot] {
        try Task.checkCancellation()
        let requested = Set(ids)
        guard !requested.isEmpty else { return [] }
        if requested.count == 1, let id = requested.first { return [try deleteColumn(id: id)] }
        let existing = try columns()
        let removed = existing.filter { requested.contains($0.id) }.sorted { $0.ordinal < $1.ordinal }
        guard removed.count == requested.count else { throw SQLiteFailure.message("A selected column no longer exists.") }
        guard existing.count - removed.count >= 1 else { throw SQLiteFailure.message("A document must retain at least one column.") }
        let storageIDs = Dictionary(uniqueKeysWithValues: removed.map { ($0.id, UUID().uuidString) })
        let select = try db.prepare("SELECT id,payload FROM rows")
        defer { sqlite3_finalize(select) }
        let updateRow = try db.prepare("UPDATE rows SET payload=? WHERE id=?")
        defer { sqlite3_finalize(updateRow) }
        let deleteColumn = try db.prepare("DELETE FROM columns WHERE id=?")
        defer { sqlite3_finalize(deleteColumn) }
        let storeCell = try db.prepare("INSERT INTO column_snapshot_cells(snapshot_id,row_id,value) VALUES(?,?,?)")
        defer { sqlite3_finalize(storeCell) }
        try db.execute("BEGIN IMMEDIATE")
        do {
            var processed = 0
            while sqlite3_step(select) == SQLITE_ROW {
                if processed.isMultiple(of: 1_000) { try Task.checkCancellation() }
                let rowID = sqlite3_column_int64(select, 0)
                let data = Data(bytes: sqlite3_column_blob(select, 1), count: Int(sqlite3_column_bytes(select, 1)))
                var values = try PackedRowCodec.decode(data)
                for column in removed {
                    let value = column.ordinal < values.count ? values[column.ordinal] : ""
                    sqlite3_reset(storeCell); sqlite3_clear_bindings(storeCell)
                    db.bind(storageIDs[column.id], at: 1, to: storeCell); db.bind(rowID, at: 2, to: storeCell)
                    db.bind(Data(value.utf8), at: 3, to: storeCell); try db.stepDone(storeCell)
                }
                for ordinal in removed.map(\.ordinal).sorted(by: >) where ordinal < values.count { values.remove(at: ordinal) }
                sqlite3_reset(updateRow); sqlite3_clear_bindings(updateRow)
                db.bind(PackedRowCodec.encode(values), at: 1, to: updateRow); db.bind(rowID, at: 2, to: updateRow)
                try db.stepDone(updateRow)
                processed += 1
            }
            for column in removed {
                sqlite3_reset(deleteColumn); sqlite3_clear_bindings(deleteColumn)
                db.bind(column.id, at: 1, to: deleteColumn); try db.stepDone(deleteColumn)
            }
            try db.execute("UPDATE columns SET ordinal=-(ordinal+1)")
            let updateOrdinal = try db.prepare("UPDATE columns SET ordinal=? WHERE id=?")
            for (newOrdinal, column) in existing.filter({ !requested.contains($0.id) }).enumerated() {
                sqlite3_reset(updateOrdinal); sqlite3_clear_bindings(updateOrdinal)
                db.bind(Int64(newOrdinal), at: 1, to: updateOrdinal); db.bind(column.id, at: 2, to: updateOrdinal)
                try db.stepDone(updateOrdinal)
            }
            sqlite3_finalize(updateOrdinal)
            try db.execute("DELETE FROM projections; DELETE FROM projected_columns; COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
        activeViewDefinition.filters.removeAll { requested.contains($0.columnID) }
        activeViewDefinition.sorts.removeAll { requested.contains($0.columnID) }
        try refreshActiveView()
        return removed.map {
            WorkspaceColumnSnapshot(id: $0.id, ordinal: $0.ordinal, name: $0.name, cells: [], storageID: storageIDs[$0.id])
        }
    }

    public func appendRow(_ values: [String]) throws -> Int64 {
        let statement = try db.prepare("SELECT COALESCE(MAX(order_key),0)+1024 FROM rows")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw SQLiteFailure.message("Could not determine row order.") }
        let projectedColumns = try builtProjectionColumns()
        let id: Int64
        try db.execute("BEGIN IMMEDIATE")
        do {
            id = try insert(values: values, orderKey: sqlite3_column_int64(statement, 0))
            try writeProjections(for: [(rowID: id, values: values)], columns: projectedColumns)
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
        try refreshActiveView()
        return id
    }

    @discardableResult
    public func insertRows(_ values: [[String]], relativeTo rowID: Int64? = nil, after: Bool = true) throws -> [WorkspaceRowSnapshot] {
        guard !values.isEmpty else { return [] }
        var bounds = try insertionBounds(relativeTo: rowID, after: after, count: values.count)
        if bounds.upper - bounds.lower <= Int64(values.count) {
            try rebalanceOrderKeys()
            bounds = try insertionBounds(relativeTo: rowID, after: after, count: values.count)
        }
        let step = (bounds.upper - bounds.lower) / Int64(values.count + 1)
        guard step > 0 else { throw SQLiteFailure.message("There is not enough room to insert rows at this position.") }
        let statement = try db.prepare("INSERT INTO rows(order_key,payload) VALUES(?,?)")
        defer { sqlite3_finalize(statement) }
        let projectedColumns = try builtProjectionColumns()
        var inserted: [WorkspaceRowSnapshot] = []
        try db.execute("BEGIN IMMEDIATE")
        do {
            for (index, row) in values.enumerated() {
                let orderKey = bounds.lower + step * Int64(index + 1)
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                db.bind(orderKey, at: 1, to: statement)
                db.bind(PackedRowCodec.encode(row), at: 2, to: statement)
                try db.stepDone(statement)
                inserted.append(WorkspaceRowSnapshot(id: sqlite3_last_insert_rowid(db.handle), orderKey: orderKey, values: row))
            }
            try writeProjections(for: inserted.map { (rowID: $0.id, values: $0.values) }, columns: projectedColumns)
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
        try refreshActiveView()
        return inserted
    }

    @discardableResult
    public func deleteRows(ids: [Int64]) throws -> [WorkspaceRowSnapshot] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let select = try db.prepare("SELECT id,order_key,payload FROM rows WHERE id IN (\(placeholders)) ORDER BY order_key")
        defer { sqlite3_finalize(select) }
        for (index, id) in ids.enumerated() { db.bind(id, at: Int32(index + 1), to: select) }
        var removed: [WorkspaceRowSnapshot] = []
        while sqlite3_step(select) == SQLITE_ROW {
            let data = Data(bytes: sqlite3_column_blob(select, 2), count: Int(sqlite3_column_bytes(select, 2)))
            removed.append(WorkspaceRowSnapshot(
                id: sqlite3_column_int64(select, 0),
                orderKey: sqlite3_column_int64(select, 1),
                values: try PackedRowCodec.decode(data)
            ))
        }
        let statement = try db.prepare("DELETE FROM rows WHERE id=?")
        defer { sqlite3_finalize(statement) }
        try db.execute("BEGIN IMMEDIATE")
        do {
            for id in ids {
                sqlite3_reset(statement)
                db.bind(id, at: 1, to: statement)
                try db.stepDone(statement)
            }
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
        try refreshActiveView()
        return removed
    }

    @discardableResult
    public func deleteRows(inVisibleRanges ranges: [Range<Int64>]) throws -> [WorkspaceRowSnapshot] {
        let ids = try rows(inVisibleRanges: ranges).map(\.id)
        return try deleteRows(ids: ids)
    }

    public func deleteRowsToSnapshot(ids: [Int64]) throws -> WorkspaceRowBatchSnapshot {
        guard !ids.isEmpty else { return WorkspaceRowBatchSnapshot(storageID: UUID().uuidString, count: 0) }
        let storageID = UUID().uuidString
        let select = try db.prepare("SELECT id,order_key,payload FROM rows WHERE id=?")
        defer { sqlite3_finalize(select) }
        let store = try db.prepare("INSERT OR IGNORE INTO row_snapshot_rows(snapshot_id,row_id,order_key,payload) VALUES(?,?,?,?)")
        defer { sqlite3_finalize(store) }
        let delete = try db.prepare("DELETE FROM rows WHERE id IN (SELECT row_id FROM row_snapshot_rows WHERE snapshot_id=?)")
        defer { sqlite3_finalize(delete) }
        var count: Int64 = 0
        try db.execute("BEGIN IMMEDIATE")
        do {
            for (index, id) in ids.enumerated() {
                if index.isMultiple(of: 1_000) { try Task.checkCancellation() }
                sqlite3_reset(select); sqlite3_clear_bindings(select); db.bind(id, at: 1, to: select)
                guard sqlite3_step(select) == SQLITE_ROW else { continue }
                let payload = Data(bytes: sqlite3_column_blob(select, 2), count: Int(sqlite3_column_bytes(select, 2)))
                sqlite3_reset(store); sqlite3_clear_bindings(store)
                db.bind(storageID, at: 1, to: store)
                db.bind(sqlite3_column_int64(select, 0), at: 2, to: store)
                db.bind(sqlite3_column_int64(select, 1), at: 3, to: store)
                db.bind(payload, at: 4, to: store)
                try db.stepDone(store)
                count += Int64(sqlite3_changes(db.handle))
            }
            db.bind(storageID, at: 1, to: delete)
            try db.stepDone(delete)
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
        if count > 0 { try refreshActiveView() }
        return WorkspaceRowBatchSnapshot(storageID: storageID, count: count)
    }

    public func deleteRowsToSnapshot(inVisibleRanges ranges: [Range<Int64>]) throws -> WorkspaceRowBatchSnapshot {
        let ranges = ranges.filter { !$0.isEmpty }
        guard !ranges.isEmpty else { return WorkspaceRowBatchSnapshot(storageID: UUID().uuidString, count: 0) }
        let storageID = UUID().uuidString
        let sql = activeView
            ? "INSERT OR IGNORE INTO row_snapshot_rows(snapshot_id,row_id,order_key,payload) SELECT ?,r.id,r.order_key,r.payload FROM view_rows v JOIN rows r ON r.id=v.row_id WHERE v.position>=? AND v.position<? ORDER BY v.position"
            : "INSERT OR IGNORE INTO row_snapshot_rows(snapshot_id,row_id,order_key,payload) SELECT ?,id,order_key,payload FROM rows ORDER BY order_key LIMIT ? OFFSET ?"
        let store = try db.prepare(sql)
        defer { sqlite3_finalize(store) }
        let countStatement = try db.prepare("SELECT COUNT(*) FROM row_snapshot_rows WHERE snapshot_id=?")
        defer { sqlite3_finalize(countStatement) }
        let delete = try db.prepare("DELETE FROM rows WHERE id IN (SELECT row_id FROM row_snapshot_rows WHERE snapshot_id=?)")
        defer { sqlite3_finalize(delete) }
        var count: Int64 = 0
        try db.execute("BEGIN IMMEDIATE")
        do {
            for range in ranges {
                try Task.checkCancellation()
                sqlite3_reset(store); sqlite3_clear_bindings(store)
                db.bind(storageID, at: 1, to: store)
                if activeView {
                    db.bind(range.lowerBound, at: 2, to: store)
                    db.bind(range.upperBound, at: 3, to: store)
                } else {
                    db.bind(Int64(range.count), at: 2, to: store)
                    db.bind(range.lowerBound, at: 3, to: store)
                }
                try db.stepDone(store)
            }
            db.bind(storageID, at: 1, to: countStatement)
            guard sqlite3_step(countStatement) == SQLITE_ROW else {
                throw SQLiteFailure.message("Could not create the row undo snapshot.")
            }
            count = sqlite3_column_int64(countStatement, 0)
            db.bind(storageID, at: 1, to: delete)
            try db.stepDone(delete)
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
        if count > 0 { try refreshActiveView() }
        return WorkspaceRowBatchSnapshot(storageID: storageID, count: count)
    }

    public func removeRows(in snapshot: WorkspaceRowBatchSnapshot) throws {
        let statement = try db.prepare("DELETE FROM rows WHERE id IN (SELECT row_id FROM row_snapshot_rows WHERE snapshot_id=?)")
        defer { sqlite3_finalize(statement) }
        db.bind(snapshot.storageID, at: 1, to: statement)
        try db.stepDone(statement)
        try refreshActiveView()
    }

    public func restoreRows(from snapshot: WorkspaceRowBatchSnapshot) throws {
        guard snapshot.count > 0 else { return }
        let select = try db.prepare("SELECT row_id,order_key,payload FROM row_snapshot_rows WHERE snapshot_id=? ORDER BY order_key")
        defer { sqlite3_finalize(select) }
        db.bind(snapshot.storageID, at: 1, to: select)
        let insert = try db.prepare("INSERT INTO rows(id,order_key,payload) VALUES(?,?,?)")
        defer { sqlite3_finalize(insert) }
        let projectedColumns = try builtProjectionColumns()
        var projectionChunk: [(rowID: Int64, values: [String])] = []
        projectionChunk.reserveCapacity(1_000)
        var restored: Int64 = 0
        try db.execute("BEGIN IMMEDIATE")
        do {
            while sqlite3_step(select) == SQLITE_ROW {
                if restored.isMultiple(of: 1_000) { try Task.checkCancellation() }
                let rowID = sqlite3_column_int64(select, 0)
                let orderKey = sqlite3_column_int64(select, 1)
                let payload = Data(bytes: sqlite3_column_blob(select, 2), count: Int(sqlite3_column_bytes(select, 2)))
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                db.bind(rowID, at: 1, to: insert)
                db.bind(orderKey, at: 2, to: insert)
                db.bind(payload, at: 3, to: insert)
                try db.stepDone(insert)
                if !projectedColumns.isEmpty {
                    projectionChunk.append((rowID: rowID, values: try PackedRowCodec.decode(payload)))
                    if projectionChunk.count == 1_000 {
                        try writeProjections(for: projectionChunk, columns: projectedColumns)
                        projectionChunk.removeAll(keepingCapacity: true)
                    }
                }
                restored += 1
            }
            try writeProjections(for: projectionChunk, columns: projectedColumns)
            guard restored == snapshot.count else {
                throw SQLiteFailure.message("The row undo snapshot is incomplete.")
            }
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
        try refreshActiveView()
    }

    public func restoreRows(_ rows: [WorkspaceRowSnapshot]) throws {
        guard !rows.isEmpty else { return }
        let statement = try db.prepare("INSERT INTO rows(id,order_key,payload) VALUES(?,?,?)")
        defer { sqlite3_finalize(statement) }
        let projectedColumns = try builtProjectionColumns()
        try db.execute("BEGIN IMMEDIATE")
        do {
            for row in rows {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                db.bind(row.id, at: 1, to: statement)
                db.bind(row.orderKey, at: 2, to: statement)
                db.bind(PackedRowCodec.encode(row.values), at: 3, to: statement)
                try db.stepDone(statement)
            }
            try writeProjections(for: rows.map { (rowID: $0.id, values: $0.values) }, columns: projectedColumns)
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
        try refreshActiveView()
    }

    public func insertPastedRows(
        _ records: [[String]],
        startingColumn: Int,
        relativeTo rowID: Int64?
    ) throws -> WorkspacePasteSnapshot {
        guard !records.isEmpty else { return WorkspacePasteSnapshot(rows: [], columns: []) }
        let startingColumn = max(0, startingColumn)
        let existingColumns = try columns()
        let requiredColumns = startingColumn + (records.map(\.count).max() ?? 0)
        let missingCount = max(0, requiredColumns - existingColumns.count)
        var bounds = try insertionBounds(relativeTo: rowID, after: true, count: records.count)
        if bounds.upper - bounds.lower <= Int64(records.count) {
            try rebalanceOrderKeys()
            bounds = try insertionBounds(relativeTo: rowID, after: true, count: records.count)
        }
        let step = (bounds.upper - bounds.lower) / Int64(records.count + 1)
        guard step > 0 else { throw SQLiteFailure.message("There is not enough room to paste rows at this position.") }
        let insertColumn = try db.prepare("INSERT INTO columns(ordinal,name) VALUES(?,?)")
        defer { sqlite3_finalize(insertColumn) }
        let insertRow = try db.prepare("INSERT INTO rows(order_key,payload) VALUES(?,?)")
        defer { sqlite3_finalize(insertRow) }
        let projectedColumns = try builtProjectionColumns()
        var addedColumns: [WorkspaceColumn] = []
        var addedRows: [WorkspaceRowSnapshot] = []
        try db.execute("BEGIN IMMEDIATE")
        do {
            if missingCount > 0 {
                for ordinal in existingColumns.count..<requiredColumns {
                    sqlite3_reset(insertColumn); sqlite3_clear_bindings(insertColumn)
                    let name = alphabeticColumnName(ordinal)
                    db.bind(Int64(ordinal), at: 1, to: insertColumn); db.bind(name, at: 2, to: insertColumn)
                    try db.stepDone(insertColumn)
                    addedColumns.append(WorkspaceColumn(id: sqlite3_last_insert_rowid(db.handle), ordinal: ordinal, name: name))
                }
            }
            let finalColumnCount = max(existingColumns.count, requiredColumns)
            for (index, record) in records.enumerated() {
                var values = Array(repeating: "", count: finalColumnCount)
                for (offset, value) in record.enumerated() { values[startingColumn + offset] = value }
                let orderKey = bounds.lower + step * Int64(index + 1)
                sqlite3_reset(insertRow); sqlite3_clear_bindings(insertRow)
                db.bind(orderKey, at: 1, to: insertRow); db.bind(PackedRowCodec.encode(values), at: 2, to: insertRow)
                try db.stepDone(insertRow)
                addedRows.append(WorkspaceRowSnapshot(id: sqlite3_last_insert_rowid(db.handle), orderKey: orderKey, values: values))
            }
            try writeProjections(for: addedRows.map { (rowID: $0.id, values: $0.values) }, columns: projectedColumns)
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
        try refreshActiveView()
        return WorkspacePasteSnapshot(rows: addedRows, columns: addedColumns)
    }

    public func removePaste(_ paste: WorkspacePasteSnapshot) throws {
        try db.execute("BEGIN IMMEDIATE")
        do {
            let deleteRow = try db.prepare("DELETE FROM rows WHERE id=?")
            for row in paste.rows {
                sqlite3_reset(deleteRow); sqlite3_clear_bindings(deleteRow)
                db.bind(row.id, at: 1, to: deleteRow); try db.stepDone(deleteRow)
            }
            sqlite3_finalize(deleteRow)
            let deleteColumn = try db.prepare("DELETE FROM columns WHERE id=?")
            for column in paste.columns.reversed() {
                sqlite3_reset(deleteColumn); sqlite3_clear_bindings(deleteColumn)
                db.bind(column.id, at: 1, to: deleteColumn); try db.stepDone(deleteColumn)
            }
            sqlite3_finalize(deleteColumn)
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
        let removedColumnIDs = Set(paste.columns.map(\.id))
        activeViewDefinition.filters.removeAll { removedColumnIDs.contains($0.columnID) }
        activeViewDefinition.sorts.removeAll { removedColumnIDs.contains($0.columnID) }
        try refreshActiveView()
    }

    public func restorePaste(_ paste: WorkspacePasteSnapshot) throws {
        let insertColumn = try db.prepare("INSERT INTO columns(id,ordinal,name) VALUES(?,?,?)")
        defer { sqlite3_finalize(insertColumn) }
        let insertRow = try db.prepare("INSERT INTO rows(id,order_key,payload) VALUES(?,?,?)")
        defer { sqlite3_finalize(insertRow) }
        let projectedColumns = try builtProjectionColumns()
        try db.execute("BEGIN IMMEDIATE")
        do {
            for column in paste.columns {
                sqlite3_reset(insertColumn); sqlite3_clear_bindings(insertColumn)
                db.bind(column.id, at: 1, to: insertColumn); db.bind(Int64(column.ordinal), at: 2, to: insertColumn)
                db.bind(column.name, at: 3, to: insertColumn); try db.stepDone(insertColumn)
            }
            for row in paste.rows {
                sqlite3_reset(insertRow); sqlite3_clear_bindings(insertRow)
                db.bind(row.id, at: 1, to: insertRow); db.bind(row.orderKey, at: 2, to: insertRow)
                db.bind(PackedRowCodec.encode(row.values), at: 3, to: insertRow); try db.stepDone(insertRow)
            }
            try writeProjections(for: paste.rows.map { (rowID: $0.id, values: $0.values) }, columns: projectedColumns)
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
        try refreshActiveView()
    }

    @discardableResult
    public func moveRows(ids: [Int64], beforeRowID: Int64?) throws -> [Int64] {
        guard !activeView else { throw SQLiteFailure.message("Clear the active sort or filter before reordering rows.") }
        let previous = try documentRowIDs()
        let movingIDs = Set(ids)
        let moving = previous.filter { movingIDs.contains($0) }
        guard !moving.isEmpty else { return previous }
        var reordered = previous.filter { !movingIDs.contains($0) }
        let insertionIndex = beforeRowID.flatMap { reordered.firstIndex(of: $0) } ?? reordered.endIndex
        reordered.insert(contentsOf: moving, at: insertionIndex)
        guard reordered != previous else { return previous }
        try setDocumentRowOrder(reordered)
        return previous
    }

    @discardableResult
    public func reorderRows(idsInDocumentOrder ids: [Int64]) throws -> [Int64] {
        guard !activeView else { throw SQLiteFailure.message("Clear the active sort or filter before reordering rows.") }
        let previous = try documentRowIDs()
        guard ids.count == previous.count, Set(ids) == Set(previous) else {
            throw SQLiteFailure.message("The requested row order does not match this document.")
        }
        guard ids != previous else { return previous }
        try setDocumentRowOrder(ids)
        return previous
    }

    public func applyView(_ definition: ViewDefinition) throws {
        for rule in definition.filters where rule.operation == .regex {
            _ = try NSRegularExpression(pattern: rule.value)
        }
        guard !definition.filters.isEmpty || !definition.sorts.isEmpty else {
            try db.execute("BEGIN IMMEDIATE")
            do {
                try db.execute("DELETE FROM view_rows; DELETE FROM metadata WHERE key='viewDefinition'; COMMIT")
            } catch {
                try? db.execute("ROLLBACK")
                throw error
            }
            activeView = false
            activeViewDefinition = .documentOrder
            return
        }
        let allColumnIDs = Set(definition.filters.map(\.columnID) + definition.sorts.map(\.columnID))
        for id in allColumnIDs { try ensureProjection(columnID: id) }

        var joins: [String] = []
        var aliases: [Int64: String] = [:]
        for (index, id) in allColumnIDs.sorted().enumerated() {
            let alias = "p\(index)"
            aliases[id] = alias
            joins.append("LEFT JOIN projections \(alias) ON \(alias).row_id=r.id AND \(alias).column_id=\(id)")
        }
        var predicates: [String] = []
        var bindings: [ViewBinding] = []
        for rule in definition.filters {
            guard let alias = aliases[rule.columnID] else { continue }
            let column = projectionColumn(rule.comparison, alias: alias)
            let value = rule.caseSensitive ? rule.value : rule.value.lowercased()
            let textColumn = rule.caseSensitive ? column : "LOWER(\(column))"
            let equalityColumn = rule.comparison == .text ? textColumn : column
            switch rule.operation {
            case .contains:
                predicates.append("\(textColumn) LIKE ? ESCAPE '\\'"); bindings.append(.text("%\(escapedLike(value))%"))
            case .doesNotContain:
                predicates.append("\(textColumn) NOT LIKE ? ESCAPE '\\'"); bindings.append(.text("%\(escapedLike(value))%"))
            case .equals: predicates.append("\(equalityColumn)=?"); bindings.append(try viewBinding(value, comparison: rule.comparison))
            case .notEqual: predicates.append("\(equalityColumn)<>?"); bindings.append(try viewBinding(value, comparison: rule.comparison))
            case .prefix: predicates.append("\(textColumn) LIKE ? ESCAPE '\\'"); bindings.append(.text("\(escapedLike(value))%"))
            case .suffix: predicates.append("\(textColumn) LIKE ? ESCAPE '\\'"); bindings.append(.text("%\(escapedLike(value))"))
            case .lessThan: predicates.append("\(column) < ?"); bindings.append(try viewBinding(value, comparison: rule.comparison))
            case .lessThanOrEqual: predicates.append("\(column) <= ?"); bindings.append(try viewBinding(value, comparison: rule.comparison))
            case .greaterThan: predicates.append("\(column) > ?"); bindings.append(try viewBinding(value, comparison: rule.comparison))
            case .greaterThanOrEqual: predicates.append("\(column) >= ?"); bindings.append(try viewBinding(value, comparison: rule.comparison))
            case .between:
                predicates.append("\(column) BETWEEN ? AND ?")
                bindings.append(try viewBinding(value, comparison: rule.comparison))
                let secondValue = rule.caseSensitive
                    ? (rule.secondValue ?? rule.value)
                    : (rule.secondValue ?? rule.value).lowercased()
                bindings.append(try viewBinding(secondValue, comparison: rule.comparison))
            case .isEmpty: predicates.append("COALESCE(\(alias).text_value,'') = ''")
            case .isNotEmpty: predicates.append("COALESCE(\(alias).text_value,'') <> ''")
            case .regex:
                predicates.append("regexp(?, \(alias).text_value)"); bindings.append(.text(rule.value))
            }
        }
        var order = definition.sorts.compactMap { rule -> String? in
            guard let alias = aliases[rule.columnID] else { return nil }
            return "\(projectionColumn(rule.comparison, alias: alias)) \(rule.ascending ? "ASC" : "DESC")"
        }
        order.append("r.order_key ASC")
        let whereClause = predicates.isEmpty ? "" : "WHERE " + predicates.joined(separator: " AND ")
        let query = "INSERT INTO view_rows(position,row_id) SELECT ROW_NUMBER() OVER (ORDER BY \(order.joined(separator: ",")))-1, r.id FROM rows r \(joins.joined(separator: " ")) \(whereClause) ORDER BY \(order.joined(separator: ","))"
        let statement = try db.prepare(query)
        defer { sqlite3_finalize(statement) }
        for (index, binding) in bindings.enumerated() {
            switch binding {
            case let .text(value): db.bind(value, at: Int32(index + 1), to: statement)
            case let .number(value): db.bind(value, at: Int32(index + 1), to: statement)
            }
        }
        let data = try JSONEncoder().encode(definition)
        let metadata = try db.prepare("INSERT OR REPLACE INTO metadata(key,value) VALUES('viewDefinition',?)")
        defer { sqlite3_finalize(metadata) }
        db.bind(String(decoding: data, as: UTF8.self), at: 1, to: metadata)
        try db.execute("BEGIN IMMEDIATE")
        do {
            try db.execute("DELETE FROM view_rows")
            try db.stepDone(statement)
            try db.stepDone(metadata)
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
        activeView = true
        activeViewDefinition = definition
    }

    public func search(_ query: String, options: SearchOptions = SearchOptions(), limit: Int = 10_000) throws -> [SearchMatch] {
        guard !query.isEmpty else { return [] }
        try Task.checkCancellation()
        let sql = activeView
            ? "SELECT r.id,r.payload FROM view_rows v JOIN rows r ON r.id=v.row_id ORDER BY v.position"
            : "SELECT id,payload FROM rows ORDER BY order_key"
        let statement = try db.prepare(sql)
        defer { sqlite3_finalize(statement) }
        let expression = options.regularExpression
            ? try NSRegularExpression(pattern: query, options: options.caseSensitive ? [] : [.caseInsensitive])
            : nil
        var matches: [SearchMatch] = []
        var processed = 0
        while sqlite3_step(statement) == SQLITE_ROW, matches.count < limit {
            if processed.isMultiple(of: 1_000) { try Task.checkCancellation() }
            let rowID = sqlite3_column_int64(statement, 0)
            let data = Data(bytes: sqlite3_column_blob(statement, 1), count: Int(sqlite3_column_bytes(statement, 1)))
            let values = try PackedRowCodec.decode(data)
            for (ordinal, value) in values.enumerated() where options.columnOrdinals?.contains(ordinal) ?? true {
                let found: Bool
                if let expression {
                    found = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
                } else if options.caseSensitive {
                    found = value.contains(query)
                } else {
                    found = value.localizedCaseInsensitiveContains(query)
                }
                if found { matches.append(SearchMatch(rowID: rowID, columnOrdinal: ordinal)) }
                if matches.count == limit { break }
            }
            processed += 1
        }
        return matches
    }

    public func replaceAll(
        _ query: String,
        replacement: String,
        options: SearchOptions = SearchOptions()
    ) throws -> WorkspaceReplacementResult {
        guard !query.isEmpty else { return WorkspaceReplacementResult(replacementCount: 0, snapshotID: nil) }
        try Task.checkCancellation()
        let expression = options.regularExpression
            ? try NSRegularExpression(pattern: query, options: options.caseSensitive ? [] : [.caseInsensitive])
            : nil
        let selectSQL = activeView
            ? "SELECT r.id,r.payload FROM view_rows v JOIN rows r ON r.id=v.row_id ORDER BY v.position"
            : "SELECT id,payload FROM rows ORDER BY order_key"
        let select = try db.prepare(selectSQL)
        defer { sqlite3_finalize(select) }
        let update = try db.prepare("UPDATE rows SET payload=? WHERE id=?")
        defer { sqlite3_finalize(update) }
        let storeSnapshot = try db.prepare("INSERT INTO replacement_snapshot_rows(snapshot_id,row_id,payload) VALUES(?,?,?)")
        defer { sqlite3_finalize(storeSnapshot) }
        let snapshotID = UUID().uuidString
        var replacementCount: Int64 = 0
        var changedColumns = Set<Int>()
        try db.execute("BEGIN IMMEDIATE")
        do {
            var processed = 0
            while sqlite3_step(select) == SQLITE_ROW {
                if processed.isMultiple(of: 1_000) { try Task.checkCancellation() }
                let rowID = sqlite3_column_int64(select, 0)
                let data = Data(bytes: sqlite3_column_blob(select, 1), count: Int(sqlite3_column_bytes(select, 1)))
                var values = try PackedRowCodec.decode(data)
                var changed = false
                for ordinal in values.indices where options.columnOrdinals?.contains(ordinal) ?? true {
                    let old = values[ordinal]
                    let new: String
                    if let expression {
                        let range = NSRange(old.startIndex..., in: old)
                        let count = expression.numberOfMatches(in: old, range: range)
                        guard count > 0 else { continue }
                        new = expression.stringByReplacingMatches(in: old, range: range, withTemplate: replacement)
                        replacementCount += Int64(count)
                    } else if options.caseSensitive {
                        let count = old.components(separatedBy: query).count - 1
                        guard count > 0 else { continue }
                        new = old.replacingOccurrences(of: query, with: replacement)
                        replacementCount += Int64(count)
                    } else {
                        var mutable = old
                        var searchRange = mutable.startIndex..<mutable.endIndex
                        var count = 0
                        while let range = mutable.range(of: query, options: [.caseInsensitive], range: searchRange) {
                            mutable.replaceSubrange(range, with: replacement)
                            count += 1
                            let next = mutable.index(range.lowerBound, offsetBy: replacement.count, limitedBy: mutable.endIndex) ?? mutable.endIndex
                            searchRange = next..<mutable.endIndex
                        }
                        guard count > 0 else { continue }
                        new = mutable
                        replacementCount += Int64(count)
                    }
                    values[ordinal] = new
                    changed = true
                    changedColumns.insert(ordinal)
                }
                if changed {
                    sqlite3_reset(storeSnapshot); sqlite3_clear_bindings(storeSnapshot)
                    db.bind(snapshotID, at: 1, to: storeSnapshot); db.bind(rowID, at: 2, to: storeSnapshot)
                    db.bind(data, at: 3, to: storeSnapshot); try db.stepDone(storeSnapshot)
                    sqlite3_reset(update); sqlite3_clear_bindings(update)
                    db.bind(PackedRowCodec.encode(values), at: 1, to: update)
                    db.bind(rowID, at: 2, to: update)
                    try db.stepDone(update)
                }
                processed += 1
            }
            for ordinal in changedColumns { try invalidateProjections(columnOrdinal: ordinal) }
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
        try refreshActiveView()
        return WorkspaceReplacementResult(
            replacementCount: replacementCount,
            snapshotID: replacementCount == 0 ? nil : snapshotID
        )
    }

    public func restoreReplacement(snapshotID: String) throws -> String {
        try Task.checkCancellation()
        let replacementSnapshotID = UUID().uuidString
        let select = try db.prepare("SELECT row_id,payload FROM replacement_snapshot_rows WHERE snapshot_id=? ORDER BY row_id")
        defer { sqlite3_finalize(select) }
        db.bind(snapshotID, at: 1, to: select)
        let current = try db.prepare("SELECT payload FROM rows WHERE id=?")
        defer { sqlite3_finalize(current) }
        let store = try db.prepare("INSERT INTO replacement_snapshot_rows(snapshot_id,row_id,payload) VALUES(?,?,?)")
        defer { sqlite3_finalize(store) }
        let update = try db.prepare("UPDATE rows SET payload=? WHERE id=?")
        defer { sqlite3_finalize(update) }
        var restoredRows = 0
        try db.execute("BEGIN IMMEDIATE")
        do {
            while sqlite3_step(select) == SQLITE_ROW {
                if restoredRows.isMultiple(of: 1_000) { try Task.checkCancellation() }
                let rowID = sqlite3_column_int64(select, 0)
                let oldLength = Int(sqlite3_column_bytes(select, 1))
                let oldPayload = Data(bytes: sqlite3_column_blob(select, 1), count: oldLength)
                sqlite3_reset(current); sqlite3_clear_bindings(current); db.bind(rowID, at: 1, to: current)
                guard sqlite3_step(current) == SQLITE_ROW else { continue }
                let currentLength = Int(sqlite3_column_bytes(current, 0))
                let currentPayload = Data(bytes: sqlite3_column_blob(current, 0), count: currentLength)
                sqlite3_reset(store); sqlite3_clear_bindings(store)
                db.bind(replacementSnapshotID, at: 1, to: store); db.bind(rowID, at: 2, to: store)
                db.bind(currentPayload, at: 3, to: store); try db.stepDone(store)
                sqlite3_reset(update); sqlite3_clear_bindings(update)
                db.bind(oldPayload, at: 1, to: update); db.bind(rowID, at: 2, to: update); try db.stepDone(update)
                restoredRows += 1
            }
            let delete = try db.prepare("DELETE FROM replacement_snapshot_rows WHERE snapshot_id=?")
            db.bind(snapshotID, at: 1, to: delete); try db.stepDone(delete); sqlite3_finalize(delete)
            try db.execute("DELETE FROM projections; DELETE FROM projected_columns; COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
        guard restoredRows > 0 else { throw SQLiteFailure.message("The Replace All undo data is no longer available.") }
        try refreshActiveView()
        return replacementSnapshotID
    }

    public func export(
        to url: URL,
        dialect outputDialect: CSVDialect? = nil,
        visibleRowsOnly: Bool = false,
        progress: ((Int64) -> Void)? = nil
    ) throws {
        let outputDialect = outputDialect ?? dialect
        let outputColumns = try columns()
        let headerOffset: Int64 = outputDialect.hasHeader ? 1 : 0
        let dataRowCount = visibleRowsOnly ? try rowCount() : try documentRowCount()
        let count = dataRowCount + headerOffset
        let stream = try SQLiteRowStream(database: db, sql:
            visibleRowsOnly && activeView
                ? "SELECT r.payload FROM view_rows v JOIN rows r ON r.id=v.row_id ORDER BY v.position"
                : "SELECT payload FROM rows ORDER BY order_key"
        )
        let writer = CSVStreamWriter(dialect: outputDialect)
        try writer.write(to: url, recordCount: count, rowAt: { index in
            if outputDialect.hasHeader && index == 0 { return outputColumns.map(\.name) }
            var values = try stream.next()
            if values.count < outputColumns.count {
                values.append(contentsOf: repeatElement("", count: outputColumns.count - values.count))
            }
            return values
        }, progress: progress)
    }

    public func exportSelection(
        to url: URL,
        visibleRanges ranges: [Range<Int64>],
        columnOrdinals: [Int],
        dialect outputDialect: CSVDialect
    ) throws -> Int64 {
        let visibleCount = try rowCount()
        let normalizedRanges = ranges.compactMap { range -> Range<Int64>? in
            let lower = min(max(0, range.lowerBound), visibleCount)
            let upper = min(max(lower, range.upperBound), visibleCount)
            return lower < upper ? lower..<upper : nil
        }
        let recordCount = normalizedRanges.reduce(Int64(0)) { $0 + Int64($1.count) }
        let stream = try SQLiteSelectedRowStream(
            database: db,
            activeView: activeView,
            ranges: normalizedRanges,
            columnOrdinals: columnOrdinals.filter { $0 >= 0 }
        )
        try CSVStreamWriter(dialect: outputDialect).write(
            to: url,
            recordCount: recordCount,
            rowAt: { _ in try stream.next() }
        )
        return recordCount
    }

    private func documentRowCount() throws -> Int64 {
        let statement = try db.prepare("SELECT COUNT(*) FROM rows")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    private func reset() throws {
        activeView = false
        activeViewDefinition = .documentOrder
        invalidateDocumentPageCursors()
        try db.execute("DELETE FROM view_rows; DELETE FROM projections; DELETE FROM projected_columns; DELETE FROM column_snapshot_cells; DELETE FROM row_snapshot_rows; DELETE FROM replacement_snapshot_rows; DELETE FROM rows; DELETE FROM columns; DELETE FROM metadata;")
    }

    private func storeDialect(_ value: CSVDialect) throws {
        dialect = value
        let data = try JSONEncoder().encode(value)
        let statement = try db.prepare("INSERT OR REPLACE INTO metadata(key,value) VALUES('dialect',?)")
        defer { sqlite3_finalize(statement) }
        db.bind(String(decoding: data, as: UTF8.self), at: 1, to: statement)
        try db.stepDone(statement)
    }

    private func storeDocumentPageCursor(_ orderKey: Int64, at offset: Int64) {
        if let existing = documentPageCursorOffsets.firstIndex(of: offset) {
            documentPageCursorOffsets.remove(at: existing)
        }
        documentPageCursors[offset] = orderKey
        documentPageCursorOffsets.append(offset)
        while documentPageCursorOffsets.count > maximumDocumentPageCursors {
            documentPageCursors.removeValue(forKey: documentPageCursorOffsets.removeFirst())
        }
    }

    private func invalidateDocumentPageCursors() {
        documentPageCursors.removeAll(keepingCapacity: true)
        documentPageCursorOffsets.removeAll(keepingCapacity: true)
    }

    private func ensureColumnCount(_ count: Int, suggestedNames: [String]) throws {
        let statement = try db.prepare("INSERT INTO columns(ordinal,name) VALUES(?,?)")
        defer { sqlite3_finalize(statement) }
        let existing = try columns().count
        guard count > existing else { return }
        for ordinal in existing..<count {
            sqlite3_reset(statement)
            db.bind(Int64(ordinal), at: 1, to: statement)
            let fallback = alphabeticColumnName(ordinal)
            db.bind(ordinal < suggestedNames.count && !suggestedNames[ordinal].isEmpty ? suggestedNames[ordinal] : fallback, at: 2, to: statement)
            try db.stepDone(statement)
        }
    }

    @discardableResult
    private func insert(values: [String], orderKey: Int64) throws -> Int64 {
        let statement = try db.prepare("INSERT INTO rows(order_key,payload) VALUES(?,?)")
        defer { sqlite3_finalize(statement) }
        db.bind(orderKey, at: 1, to: statement)
        db.bind(PackedRowCodec.encode(values), at: 2, to: statement)
        try db.stepDone(statement)
        return sqlite3_last_insert_rowid(db.handle)
    }

    private func values(for rowID: Int64) throws -> [String] {
        let statement = try db.prepare("SELECT payload FROM rows WHERE id=?")
        defer { sqlite3_finalize(statement) }
        db.bind(rowID, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw SQLiteFailure.message("The row no longer exists.") }
        return try PackedRowCodec.decode(Data(bytes: sqlite3_column_blob(statement, 0), count: Int(sqlite3_column_bytes(statement, 0))))
    }

    private func insertColumn(
        at requestedOrdinal: Int,
        name requestedName: String?,
        id requestedID: Int64?,
        cellValues: [Int64: String],
        snapshotStorageID: String? = nil,
        copyingOrdinal: Int? = nil
    ) throws -> WorkspaceColumn {
        try Task.checkCancellation()
        let existing = try columns()
        let ordinal = min(max(requestedOrdinal, 0), existing.count)
        let name = requestedName ?? alphabeticColumnName(ordinal)
        let select = try db.prepare("SELECT id,payload FROM rows")
        defer { sqlite3_finalize(select) }
        let updateRow = try db.prepare("UPDATE rows SET payload=? WHERE id=?")
        defer { sqlite3_finalize(updateRow) }
        var snapshotLookup: OpaquePointer?
        if snapshotStorageID != nil {
            snapshotLookup = try db.prepare("SELECT value FROM column_snapshot_cells WHERE snapshot_id=? AND row_id=?")
        }
        defer { if let snapshotLookup { sqlite3_finalize(snapshotLookup) } }
        try db.execute("BEGIN IMMEDIATE")
        do {
            try db.execute("""
            UPDATE columns SET ordinal=-(ordinal+1);
            UPDATE columns SET ordinal=CASE
                WHEN (-ordinal)-1 >= \(ordinal) THEN -ordinal
                ELSE (-ordinal)-1
            END;
            """)
            let insertColumn: OpaquePointer
            if let requestedID {
                insertColumn = try db.prepare("INSERT INTO columns(id,ordinal,name) VALUES(?,?,?)")
                db.bind(requestedID, at: 1, to: insertColumn)
                db.bind(Int64(ordinal), at: 2, to: insertColumn)
                db.bind(name, at: 3, to: insertColumn)
            } else {
                insertColumn = try db.prepare("INSERT INTO columns(ordinal,name) VALUES(?,?)")
                db.bind(Int64(ordinal), at: 1, to: insertColumn)
                db.bind(name, at: 2, to: insertColumn)
            }
            try db.stepDone(insertColumn)
            let insertedID = requestedID ?? sqlite3_last_insert_rowid(db.handle)
            sqlite3_finalize(insertColumn)

            var processed = 0
            while sqlite3_step(select) == SQLITE_ROW {
                if processed.isMultiple(of: 1_000) { try Task.checkCancellation() }
                let rowID = sqlite3_column_int64(select, 0)
                let data = Data(bytes: sqlite3_column_blob(select, 1), count: Int(sqlite3_column_bytes(select, 1)))
                var values = try PackedRowCodec.decode(data)
                while values.count < existing.count { values.append("") }
                var insertedValue = cellValues[rowID] ?? ""
                if let copyingOrdinal, copyingOrdinal < values.count {
                    insertedValue = values[copyingOrdinal]
                }
                if let snapshotStorageID, let snapshotLookup {
                    sqlite3_reset(snapshotLookup); sqlite3_clear_bindings(snapshotLookup)
                    db.bind(snapshotStorageID, at: 1, to: snapshotLookup); db.bind(rowID, at: 2, to: snapshotLookup)
                    if sqlite3_step(snapshotLookup) == SQLITE_ROW {
                        let valueLength = Int(sqlite3_column_bytes(snapshotLookup, 0))
                        let valueData = valueLength == 0
                            ? Data()
                            : Data(bytes: sqlite3_column_blob(snapshotLookup, 0), count: valueLength)
                        insertedValue = String(decoding: valueData, as: UTF8.self)
                    }
                }
                values.insert(insertedValue, at: ordinal)
                sqlite3_reset(updateRow); sqlite3_clear_bindings(updateRow)
                db.bind(PackedRowCodec.encode(values), at: 1, to: updateRow)
                db.bind(rowID, at: 2, to: updateRow)
                try db.stepDone(updateRow)
                processed += 1
            }
            if let snapshotStorageID {
                let deleteSnapshot = try db.prepare("DELETE FROM column_snapshot_cells WHERE snapshot_id=?")
                db.bind(snapshotStorageID, at: 1, to: deleteSnapshot)
                try db.stepDone(deleteSnapshot)
                sqlite3_finalize(deleteSnapshot)
            }
            try db.execute("DELETE FROM projections; DELETE FROM projected_columns; COMMIT")
            try refreshActiveView()
            return WorkspaceColumn(id: insertedID, ordinal: ordinal, name: name)
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    private func insertionBounds(relativeTo rowID: Int64?, after: Bool, count: Int) throws -> (lower: Int64, upper: Int64) {
        guard let rowID else {
            let statement = try db.prepare("SELECT COALESCE(MAX(order_key),0) FROM rows")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw SQLiteFailure.message("Could not determine row order.") }
            let lower = sqlite3_column_int64(statement, 0)
            return (lower, lower + Int64(count + 1) * 1_024)
        }
        let targetStatement = try db.prepare("SELECT order_key FROM rows WHERE id=?")
        defer { sqlite3_finalize(targetStatement) }
        db.bind(rowID, at: 1, to: targetStatement)
        guard sqlite3_step(targetStatement) == SQLITE_ROW else { throw SQLiteFailure.message("The selected row no longer exists.") }
        let target = sqlite3_column_int64(targetStatement, 0)
        let neighborSQL = after
            ? "SELECT MIN(order_key) FROM rows WHERE order_key>?"
            : "SELECT MAX(order_key) FROM rows WHERE order_key<?"
        let neighbor = try db.prepare(neighborSQL)
        defer { sqlite3_finalize(neighbor) }
        db.bind(target, at: 1, to: neighbor)
        guard sqlite3_step(neighbor) == SQLITE_ROW else { throw SQLiteFailure.message("Could not determine row order.") }
        if sqlite3_column_type(neighbor, 0) == SQLITE_NULL {
            return after
                ? (target, target + Int64(count + 1) * 1_024)
                : (target - Int64(count + 1) * 1_024, target)
        }
        let neighborKey = sqlite3_column_int64(neighbor, 0)
        return after ? (target, neighborKey) : (neighborKey, target)
    }

    private func documentRowIDs() throws -> [Int64] {
        try Task.checkCancellation()
        let statement = try db.prepare("SELECT id FROM rows ORDER BY order_key")
        defer { sqlite3_finalize(statement) }
        var ids: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if ids.count.isMultiple(of: 1_000) { try Task.checkCancellation() }
            ids.append(sqlite3_column_int64(statement, 0))
        }
        return ids
    }

    private func setDocumentRowOrder(_ ids: [Int64]) throws {
        try Task.checkCancellation()
        try db.execute("BEGIN IMMEDIATE; CREATE TEMP TABLE requested_row_order(id INTEGER PRIMARY KEY, final_key INTEGER NOT NULL UNIQUE)")
        do {
            do {
                let insert = try db.prepare("INSERT INTO requested_row_order(id,final_key) VALUES(?,?)")
                defer { sqlite3_finalize(insert) }
                for (index, id) in ids.enumerated() {
                    if index.isMultiple(of: 1_000) { try Task.checkCancellation() }
                    sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                    db.bind(id, at: 1, to: insert); db.bind(Int64(index + 1) * 1_024, at: 2, to: insert)
                    try db.stepDone(insert)
                }
            }
            try Task.checkCancellation()
            try db.execute("""
            UPDATE rows SET order_key=-4000000000000000000 + (SELECT final_key / 1024 FROM requested_row_order WHERE requested_row_order.id=rows.id);
            UPDATE rows SET order_key=(SELECT final_key FROM requested_row_order WHERE requested_row_order.id=rows.id);
            DROP TABLE requested_row_order;
            COMMIT;
            """)
        } catch {
            try? db.execute("ROLLBACK; DROP TABLE IF EXISTS requested_row_order")
            throw error
        }
    }

    private func rebalanceOrderKeys() throws {
        try Task.checkCancellation()
        try db.execute("BEGIN IMMEDIATE")
        do {
            try db.execute("""
            CREATE TEMP TABLE row_rebalance(id INTEGER PRIMARY KEY, final_key INTEGER NOT NULL UNIQUE);
            INSERT INTO row_rebalance(id,final_key)
                SELECT id, ROW_NUMBER() OVER (ORDER BY order_key) * 1024 FROM rows;
            UPDATE rows SET order_key=-4000000000000000000 + (SELECT final_key / 1024 FROM row_rebalance WHERE row_rebalance.id=rows.id);
            UPDATE rows SET order_key=(SELECT final_key FROM row_rebalance WHERE row_rebalance.id=rows.id);
            DROP TABLE row_rebalance;
            COMMIT;
            """)
        } catch {
            try? db.execute("ROLLBACK; DROP TABLE IF EXISTS row_rebalance")
            throw error
        }
    }

    private func columnID(at ordinal: Int) throws -> Int64? {
        let statement = try db.prepare("SELECT id FROM columns WHERE ordinal=?")
        defer { sqlite3_finalize(statement) }
        db.bind(Int64(ordinal), at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func builtProjectionColumns() throws -> [(id: Int64, ordinal: Int)] {
        let statement = try db.prepare("""
        SELECT c.id,c.ordinal
        FROM projected_columns p JOIN columns c ON c.id=p.column_id
        ORDER BY c.ordinal
        """)
        defer { sqlite3_finalize(statement) }
        var result: [(id: Int64, ordinal: Int)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((
                id: sqlite3_column_int64(statement, 0),
                ordinal: Int(sqlite3_column_int64(statement, 1))
            ))
        }
        return result
    }

    private func writeProjections(
        for rows: [(rowID: Int64, values: [String])],
        columns: [(id: Int64, ordinal: Int)]
    ) throws {
        guard !rows.isEmpty, !columns.isEmpty else { return }
        let statement = try db.prepare("""
        INSERT OR REPLACE INTO projections(row_id,column_id,text_value,numeric_value,date_value)
        VALUES(?,?,?,?,?)
        """)
        defer { sqlite3_finalize(statement) }
        let dateFormatter = ISO8601DateFormatter()
        let dateOnlyFormatter = ISO8601DateFormatter()
        dateOnlyFormatter.formatOptions = [.withFullDate]
        var processed = 0
        for row in rows {
            for column in columns {
                if processed.isMultiple(of: 1_000) { try Task.checkCancellation() }
                let value = column.ordinal < row.values.count ? row.values[column.ordinal] : ""
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                db.bind(row.rowID, at: 1, to: statement)
                db.bind(column.id, at: 2, to: statement)
                db.bind(value, at: 3, to: statement)
                db.bind(Double(normalizedNumber(value)), at: 4, to: statement)
                let date = iso8601Date(value, formatter: dateFormatter, dateOnlyFormatter: dateOnlyFormatter)
                db.bind(date?.timeIntervalSince1970, at: 5, to: statement)
                try db.stepDone(statement)
                processed += 1
            }
        }
    }

    private func activeViewReferences(columnID: Int64) -> Bool {
        activeView && (
            activeViewDefinition.filters.contains(where: { $0.columnID == columnID })
                || activeViewDefinition.sorts.contains(where: { $0.columnID == columnID })
        )
    }

    private func ensureProjection(columnID: Int64) throws {
        try Task.checkCancellation()
        let lookup = try db.prepare("SELECT 1 FROM projected_columns WHERE column_id=?")
        db.bind(columnID, at: 1, to: lookup)
        let exists = sqlite3_step(lookup) == SQLITE_ROW
        sqlite3_finalize(lookup)
        if exists { return }
        let columnStatement = try db.prepare("SELECT ordinal FROM columns WHERE id=?")
        defer { sqlite3_finalize(columnStatement) }
        db.bind(columnID, at: 1, to: columnStatement)
        guard sqlite3_step(columnStatement) == SQLITE_ROW else { return }
        let ordinal = Int(sqlite3_column_int64(columnStatement, 0))

        let delete = try db.prepare("DELETE FROM projections WHERE column_id=?")
        db.bind(columnID, at: 1, to: delete); try db.stepDone(delete); sqlite3_finalize(delete)
        let select = try db.prepare("SELECT id,payload FROM rows")
        defer { sqlite3_finalize(select) }
        let insert = try db.prepare("INSERT INTO projections(row_id,column_id,text_value,numeric_value,date_value) VALUES(?,?,?,?,?)")
        defer { sqlite3_finalize(insert) }
        let dateFormatter = ISO8601DateFormatter()
        let dateOnlyFormatter = ISO8601DateFormatter()
        dateOnlyFormatter.formatOptions = [.withFullDate]
        try db.execute("BEGIN IMMEDIATE")
        do {
            var processed = 0
            while sqlite3_step(select) == SQLITE_ROW {
                if processed.isMultiple(of: 1_000) { try Task.checkCancellation() }
                let rowID = sqlite3_column_int64(select, 0)
                let data = Data(bytes: sqlite3_column_blob(select, 1), count: Int(sqlite3_column_bytes(select, 1)))
                let values = try PackedRowCodec.decode(data)
                let value = ordinal < values.count ? values[ordinal] : ""
                let normalizedNumericText = normalizedNumber(value)
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                db.bind(rowID, at: 1, to: insert); db.bind(columnID, at: 2, to: insert)
                db.bind(value, at: 3, to: insert); db.bind(Double(normalizedNumericText), at: 4, to: insert)
                let date = iso8601Date(value, formatter: dateFormatter, dateOnlyFormatter: dateOnlyFormatter)
                db.bind(date?.timeIntervalSince1970, at: 5, to: insert)
                try db.stepDone(insert)
                processed += 1
            }
            try Task.checkCancellation()
            let marker = try db.prepare("INSERT OR REPLACE INTO projected_columns(column_id) VALUES(?)")
            db.bind(columnID, at: 1, to: marker); try db.stepDone(marker); sqlite3_finalize(marker)
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    private func invalidateProjections(columnOrdinal: Int) throws {
        let statement = try db.prepare("DELETE FROM projected_columns WHERE column_id=(SELECT id FROM columns WHERE ordinal=?)")
        defer { sqlite3_finalize(statement) }
        db.bind(Int64(columnOrdinal), at: 1, to: statement)
        try db.stepDone(statement)
    }

    private func refreshActiveView() throws {
        invalidateDocumentPageCursors()
        guard activeView else { return }
        try applyView(activeViewDefinition)
    }

    private func projectionColumn(_ comparison: ColumnComparison, alias: String) -> String {
        switch comparison {
        case .text: "\(alias).text_value"
        case .number: "\(alias).numeric_value"
        case .date: "\(alias).date_value"
        }
    }

    private func viewBinding(_ value: String, comparison: ColumnComparison) throws -> ViewBinding {
        switch comparison {
        case .text:
            return .text(value)
        case .number:
            guard let number = Double(normalizedNumber(value)) else {
                throw SQLiteFailure.message("\(value) is not a valid number for this document's decimal mark.")
            }
            return .number(number)
        case .date:
            let formatter = ISO8601DateFormatter()
            let dateOnlyFormatter = ISO8601DateFormatter()
            dateOnlyFormatter.formatOptions = [.withFullDate]
            guard let date = iso8601Date(value, formatter: formatter, dateOnlyFormatter: dateOnlyFormatter) else {
                throw SQLiteFailure.message("\(value) is not a valid ISO-8601 date.")
            }
            return .number(date.timeIntervalSince1970)
        }
    }

    private func normalizedNumber(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: String(dialect.decimalMark), with: ".")
    }

    private func iso8601Date(
        _ value: String,
        formatter: ISO8601DateFormatter,
        dateOnlyFormatter: ISO8601DateFormatter
    ) -> Date? {
        // ISO8601DateFormatter is comparatively expensive even for immediate failures.
        // All formats accepted here begin with YYYY-MM-DD, so avoid both parsers for the
        // overwhelmingly common text and numeric projection values.
        let bytes = value.utf8
        guard bytes.count >= 10 else { return nil }
        let fourth = bytes.index(bytes.startIndex, offsetBy: 4)
        let seventh = bytes.index(bytes.startIndex, offsetBy: 7)
        guard bytes[fourth] == 45, bytes[seventh] == 45 else { return nil }
        return formatter.date(from: value) ?? dateOnlyFormatter.date(from: value)
    }

    private func escapedLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func alphabeticColumnName(_ index: Int) -> String {
        var number = index + 1
        var result = ""
        while number > 0 {
            number -= 1
            result.insert(Character(UnicodeScalar(65 + number % 26)!), at: result.startIndex)
            number /= 26
        }
        return result
    }

    private static let schema = """
    CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS columns(id INTEGER PRIMARY KEY, ordinal INTEGER NOT NULL UNIQUE, name TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS rows(id INTEGER PRIMARY KEY, order_key INTEGER NOT NULL UNIQUE, payload BLOB NOT NULL);
    CREATE TABLE IF NOT EXISTS view_rows(position INTEGER PRIMARY KEY, row_id INTEGER NOT NULL REFERENCES rows(id) ON DELETE CASCADE);
    CREATE UNIQUE INDEX IF NOT EXISTS view_row_id ON view_rows(row_id);
    CREATE TABLE IF NOT EXISTS projections(
        row_id INTEGER NOT NULL REFERENCES rows(id) ON DELETE CASCADE,
        column_id INTEGER NOT NULL REFERENCES columns(id) ON DELETE CASCADE,
        text_value TEXT,
        numeric_value REAL,
        date_value REAL,
        PRIMARY KEY(row_id,column_id)
    );
    CREATE TABLE IF NOT EXISTS projected_columns(column_id INTEGER PRIMARY KEY REFERENCES columns(id) ON DELETE CASCADE);
    CREATE TABLE IF NOT EXISTS column_snapshot_cells(
        snapshot_id TEXT NOT NULL,
        row_id INTEGER NOT NULL,
        value BLOB NOT NULL,
        PRIMARY KEY(snapshot_id,row_id)
    );
    CREATE TABLE IF NOT EXISTS row_snapshot_rows(
        snapshot_id TEXT NOT NULL,
        row_id INTEGER NOT NULL,
        order_key INTEGER NOT NULL,
        payload BLOB NOT NULL,
        PRIMARY KEY(snapshot_id,row_id)
    );
    CREATE INDEX IF NOT EXISTS row_snapshot_lookup ON row_snapshot_rows(snapshot_id,order_key);
    CREATE TABLE IF NOT EXISTS replacement_snapshot_rows(
        snapshot_id TEXT NOT NULL,
        row_id INTEGER NOT NULL,
        payload BLOB NOT NULL,
        PRIMARY KEY(snapshot_id,row_id)
    );
    CREATE INDEX IF NOT EXISTS projection_text ON projections(column_id,text_value,row_id);
    CREATE INDEX IF NOT EXISTS projection_number ON projections(column_id,numeric_value,row_id);
    CREATE INDEX IF NOT EXISTS projection_date ON projections(column_id,date_value,row_id);
    """
}

/// Owns the mutable state used by the parser's synchronous callbacks. Keeping the SQLite
/// statement and counters together also avoids older Swift 6 compilers incorrectly treating
/// a deferred statement finalizer as concurrent with an actor-isolated callback.
private final class CSVImportAccumulator: @unchecked Sendable {
    private let database: SQLiteConnection
    private let dialect: CSVDialect
    private let insertStatement: OpaquePointer
    private var imported: Int64 = 0
    private var nextOrder: Int64 = 1_024
    private(set) var header: [String]?
    private(set) var maximumColumns = 0
    private var previewRows: [WorkspaceRow] = []

    init(database: SQLiteConnection, dialect: CSVDialect) throws {
        self.database = database
        self.dialect = dialect
        insertStatement = try database.prepare("INSERT INTO rows(order_key, payload) VALUES(?, ?)")
    }

    deinit {
        sqlite3_finalize(insertStatement)
    }

    func consume(_ record: CSVRecord) throws {
        if dialect.hasHeader && header == nil {
            header = record.values
            maximumColumns = max(maximumColumns, record.values.count)
            return
        }
        maximumColumns = max(maximumColumns, record.values.count)
        sqlite3_reset(insertStatement)
        sqlite3_clear_bindings(insertStatement)
        database.bind(nextOrder, at: 1, to: insertStatement)
        database.bind(PackedRowCodec.encode(record.values), at: 2, to: insertStatement)
        try database.stepDone(insertStatement)
        let rowID = sqlite3_last_insert_rowid(database.handle)
        if previewRows.count < 256 {
            previewRows.append(WorkspaceRow(id: rowID, values: record.values))
        }
        imported += 1
        nextOrder += 1_024
    }

    func progress(bytesRead: Int64, totalBytes: Int64) -> WorkspaceImportProgress {
        WorkspaceImportProgress(
            bytesRead: bytesRead,
            totalBytes: totalBytes,
            rowsImported: imported,
            previewRows: previewRows,
            header: header,
            maximumColumnCount: maximumColumns
        )
    }
}

private final class SQLiteRowStream: @unchecked Sendable {
    private let database: SQLiteConnection
    private let statement: OpaquePointer

    init(database: SQLiteConnection, sql: String) throws {
        self.database = database
        statement = try database.prepare(sql)
    }

    deinit {
        sqlite3_finalize(statement)
    }

    func next() throws -> [String] {
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteFailure.message(String(cString: sqlite3_errmsg(database.handle)))
        }
        let length = Int(sqlite3_column_bytes(statement, 0))
        let data = Data(bytes: sqlite3_column_blob(statement, 0), count: length)
        return try PackedRowCodec.decode(data)
    }
}

private final class SQLiteSelectedRowStream: @unchecked Sendable {
    private let database: SQLiteConnection
    private let activeView: Bool
    private let ranges: [Range<Int64>]
    private let columnOrdinals: [Int]
    private var rangeIndex = 0
    private var statement: OpaquePointer?

    init(
        database: SQLiteConnection,
        activeView: Bool,
        ranges: [Range<Int64>],
        columnOrdinals: [Int]
    ) throws {
        self.database = database
        self.activeView = activeView
        self.ranges = ranges
        self.columnOrdinals = columnOrdinals
        try prepareNextRange()
    }

    deinit {
        if let statement { sqlite3_finalize(statement) }
    }

    func next() throws -> [String] {
        while let statement {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                let length = Int(sqlite3_column_bytes(statement, 0))
                let data = Data(bytes: sqlite3_column_blob(statement, 0), count: length)
                let values = try PackedRowCodec.decode(data)
                return columnOrdinals.map { $0 < values.count ? values[$0] : "" }
            }
            guard result == SQLITE_DONE else {
                throw SQLiteFailure.message(String(cString: sqlite3_errmsg(database.handle)))
            }
            sqlite3_finalize(statement)
            self.statement = nil
            try prepareNextRange()
        }
        throw SQLiteFailure.message("The selected row stream ended unexpectedly.")
    }

    private func prepareNextRange() throws {
        guard rangeIndex < ranges.count else { return }
        let range = ranges[rangeIndex]
        rangeIndex += 1
        let sql = activeView
            ? "SELECT r.payload FROM view_rows v JOIN rows r ON r.id=v.row_id WHERE v.position>=? AND v.position<? ORDER BY v.position"
            : "SELECT payload FROM rows ORDER BY order_key LIMIT ? OFFSET ?"
        let statement = try database.prepare(sql)
        if activeView {
            database.bind(range.lowerBound, at: 1, to: statement)
            database.bind(range.upperBound, at: 2, to: statement)
        } else {
            database.bind(Int64(range.count), at: 1, to: statement)
            database.bind(range.lowerBound, at: 2, to: statement)
        }
        self.statement = statement
    }
}
