import XCTest
@testable import TableToolCore

final class WorkspaceTests: XCTestCase {
    func testCancelledImportLeavesNoPartialRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("large.csv")
        let body = String(repeating: "identifier,value that must never be partially committed\n", count: 100_000)
        try Data(("id,value\n" + body).utf8).write(to: source)
        let workspace = try DocumentWorkspace(databaseURL: root.appendingPathComponent("workspace.sqlite"))

        let importTask = Task {
            try await workspace.importCSV(from: source, dialect: .standard)
        }
        importTask.cancel()
        do {
            _ = try await importTask.value
            XCTFail("Expected import cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let rowCount = try await workspace.rowCount()
        XCTAssertEqual(rowCount, 0)
    }

    func testBulkImportTruncatesCheckpointedWriteAheadLog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.csv")
        let body = String(repeating: "identifier,a moderately sized value for the WAL\n", count: 20_000)
        try Data(("id,value\n" + body).utf8).write(to: source)
        let database = root.appendingPathComponent("workspace.sqlite")
        let workspace = try DocumentWorkspace(databaseURL: database)

        _ = try await workspace.importCSV(from: source, dialect: .standard)

        let rowCount = try await workspace.rowCount()
        XCTAssertEqual(rowCount, 20_000)
        let wal = URL(fileURLWithPath: database.path + "-wal")
        let walSize = (try? wal.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        XCTAssertLessThanOrEqual(walSize, 4_096)
    }

    func testImportEditFilterSortAndExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.csv")
        try Data("code,amount\n001,20.00\n010,3.50\n002,12.00\n".utf8).write(to: source)
        let workspace = try DocumentWorkspace(databaseURL: root.appendingPathComponent("workspace.sqlite"))
        _ = try await workspace.importCSV(from: source, dialect: .standard)

        let columns = try await workspace.columns()
        XCTAssertEqual(columns.map(\.name), ["code", "amount"])
        let importedCount = try await workspace.rowCount()
        XCTAssertEqual(importedCount, 3)

        let first = try await workspace.page(offset: 0, limit: 1).rows[0]
        XCTAssertEqual(first.values[0], "001")
        _ = try await workspace.updateCell(rowID: first.id, columnOrdinal: 0, value: "0001")

        try await workspace.applyView(ViewDefinition(
            filters: [FilterRule(columnID: columns[1].id, comparison: .number, operation: .greaterThan, value: "4")],
            sorts: [SortRule(columnID: columns[1].id, comparison: .number, ascending: true)]
        ))
        let page = try await workspace.page(offset: 0, limit: 10)
        XCTAssertEqual(page.rows.map { $0.values[1] }, ["12.00", "20.00"])

        let output = root.appendingPathComponent("output.csv")
        try await workspace.export(to: output)
        let exported = try CSVStreamParser(dialect: .standard).parse(data: Data(contentsOf: output)).map(\.values)
        XCTAssertEqual(exported[0], ["code", "amount"])
        XCTAssertEqual(exported[1][0], "0001")
    }

    func testEmbeddedNullInHeaderSurvivesWorkspaceAndExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.csv")
        try Data("head\0er,second\nvalue,other\n".utf8).write(to: source)
        let workspace = try DocumentWorkspace(databaseURL: root.appendingPathComponent("workspace.sqlite"))
        _ = try await workspace.importCSV(from: source, dialect: .standard)

        let columns = try await workspace.columns()
        XCTAssertEqual(columns.map(\.name), ["head\0er", "second"])
        let output = root.appendingPathComponent("output.csv")
        try await workspace.export(to: output)
        let records = try CSVStreamParser(dialect: .standard).parse(data: Data(contentsOf: output))
        XCTAssertEqual(records[0].values, ["head\0er", "second"])
    }

    func testExportPadsRaggedRowsToDisplayedColumnCount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("ragged.csv")
        try Data("first,second,third\none\ntwo,values\nthree,values,complete\n".utf8).write(to: source)
        let workspace = try DocumentWorkspace(databaseURL: root.appendingPathComponent("workspace.sqlite"))
        _ = try await workspace.importCSV(from: source, dialect: .standard)

        let output = root.appendingPathComponent("output.csv")
        try await workspace.export(to: output)
        let exported = try CSVStreamParser(dialect: .standard)
            .parse(data: Data(contentsOf: output)).map(\.values)
        XCTAssertEqual(exported, [
            ["first", "second", "third"],
            ["one", "", ""],
            ["two", "values", ""],
            ["three", "values", "complete"],
        ])
    }

    func testColumnReorderChangesRowsAndExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.csv")
        try Data("first,second,third\na,b,c\n".utf8).write(to: source)
        let workspace = try DocumentWorkspace(databaseURL: root.appendingPathComponent("workspace.sqlite"))
        _ = try await workspace.importCSV(from: source, dialect: .standard)

        let original = try await workspace.columns()
        try await workspace.reorderColumns(ids: [original[2].id, original[0].id, original[1].id])
        let reorderedColumns = try await workspace.columns()
        let reorderedPage = try await workspace.page(offset: 0, limit: 1)
        XCTAssertEqual(reorderedColumns.map(\.name), ["third", "first", "second"])
        XCTAssertEqual(reorderedPage.rows[0].values, ["c", "a", "b"])

        let output = root.appendingPathComponent("output.csv")
        try await workspace.export(to: output)
        let exported = try CSVStreamParser(dialect: .standard).parse(data: Data(contentsOf: output)).map(\.values)
        XCTAssertEqual(exported, [["third", "first", "second"], ["c", "a", "b"]])
    }

    func testVisibleExportStreamsFilteredRowsInSortOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.csv")
        try Data("name,score\nAda,9\nGrace,10\nLinus,3\n".utf8).write(to: source)
        let workspace = try DocumentWorkspace(databaseURL: root.appendingPathComponent("workspace.sqlite"))
        _ = try await workspace.importCSV(from: source, dialect: .standard)
        let columns = try await workspace.columns()
        try await workspace.applyView(ViewDefinition(
            filters: [FilterRule(columnID: columns[1].id, comparison: .number, operation: .greaterThan, value: "5")],
            sorts: [SortRule(columnID: columns[1].id, comparison: .number, ascending: false)]
        ))

        let output = root.appendingPathComponent("visible.csv")
        try await workspace.export(to: output, visibleRowsOnly: true)
        let exported = try CSVStreamParser(dialect: .standard).parse(data: Data(contentsOf: output)).map(\.values)
        XCTAssertEqual(exported, [["name", "score"], ["Grace", "10"], ["Ada", "9"]])

        var clipboardDialect = CSVDialect.tsv
        clipboardDialect.hasHeader = false
        clipboardDialect.hasFinalNewline = false
        let selection = root.appendingPathComponent("selection.tsv")
        let copiedCount = try await workspace.exportSelection(
            to: selection,
            visibleRanges: [0..<1, 1..<2],
            columnOrdinals: [1, 0],
            dialect: clipboardDialect
        )
        let copied = try CSVStreamParser(dialect: clipboardDialect)
            .parse(data: Data(contentsOf: selection)).map(\.values)
        XCTAssertEqual(copiedCount, 2)
        XCTAssertEqual(copied, [["10", "Grace"], ["9", "Ada"]])
    }

    func testTypedFiltersBindCommaDecimalsAndISODateOnlyValues() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.csv")
        try Data("name;amount;date\nEarlier;4,4;2025-01-01\nLater;4,6;2026-01-01\n".utf8).write(to: source)
        let dialect = CSVDialect(delimiter: ";", decimalMark: ",")
        let workspace = try DocumentWorkspace(databaseURL: root.appendingPathComponent("workspace.sqlite"))
        _ = try await workspace.importCSV(from: source, dialect: dialect)
        let columns = try await workspace.columns()

        try await workspace.applyView(ViewDefinition(filters: [
            FilterRule(columnID: columns[1].id, comparison: .number, operation: .greaterThan, value: "4,5")
        ]))
        var page = try await workspace.page(offset: 0, limit: 10)
        XCTAssertEqual(page.rows.map { $0.values[0] }, ["Later"])

        try await workspace.applyView(ViewDefinition(filters: [
            FilterRule(columnID: columns[2].id, comparison: .date, operation: .greaterThan, value: "2025-06-01")
        ]))
        page = try await workspace.page(offset: 0, limit: 10)
        XCTAssertEqual(page.rows.map { $0.values[0] }, ["Later"])
    }

    func testFilteredSortedViewStaysCorrectAfterMutationsAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.csv")
        try Data("name,score\nAda,1\nGrace,10\nLinus,20\n".utf8).write(to: source)
        let database = root.appendingPathComponent("workspace.sqlite")
        let workspace = try DocumentWorkspace(databaseURL: database)
        _ = try await workspace.importCSV(from: source, dialect: .standard)
        let score = try await workspace.columns()[1]
        let definition = ViewDefinition(
            filters: [FilterRule(columnID: score.id, comparison: .number, operation: .greaterThan, value: "5")],
            sorts: [SortRule(columnID: score.id, comparison: .number, ascending: false)]
        )
        try await workspace.applyView(definition)
        var page = try await workspace.page(offset: 0, limit: 10)
        XCTAssertEqual(page.rows.map { $0.values[0] }, ["Linus", "Grace"])
        guard let linus = page.rows.first else { return XCTFail("The filtered view unexpectedly contained no rows.") }

        _ = try await workspace.updateCell(rowID: linus.id, columnOrdinal: 0, value: "Kernel")
        page = try await workspace.page(offset: 0, limit: 10)
        XCTAssertEqual(page.rows.map { $0.values[0] }, ["Kernel", "Grace"])
        _ = try await workspace.updateCell(rowID: linus.id, columnOrdinal: 1, value: "0")
        _ = try await workspace.appendRow(["Margaret", "30"])
        page = try await workspace.page(offset: 0, limit: 10)
        XCTAssertEqual(page.rows.map { $0.values[0] }, ["Margaret", "Grace"])
        guard page.rows.count == 2 else { return XCTFail("The refreshed view did not contain the expected rows.") }
        try await workspace.deleteRows(ids: [page.rows[1].id])
        let afterDelete = try await workspace.page(offset: 0, limit: 10)
        XCTAssertEqual(afterDelete.rows.map { $0.values[0] }, ["Margaret"])

        let reopened = try DocumentWorkspace(databaseURL: database)
        let restoredView = try await reopened.page(offset: 0, limit: 10)
        let restoredDefinition = await reopened.currentViewDefinition()
        XCTAssertEqual(restoredView.rows.map { $0.values[0] }, ["Margaret"])
        XCTAssertEqual(restoredDefinition, definition)
    }

    func testSearchAndVisibleIndexesRespectTheActiveView() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.csv")
        try Data("name,score\nAda,9\nGrace,10\nLinus,3\n".utf8).write(to: source)
        let workspace = try DocumentWorkspace(databaseURL: root.appendingPathComponent("workspace.sqlite"))
        _ = try await workspace.importCSV(from: source, dialect: .standard)
        let score = try await workspace.columns()[1]
        try await workspace.applyView(ViewDefinition(
            filters: [FilterRule(columnID: score.id, comparison: .number, operation: .greaterThan, value: "5")],
            sorts: [SortRule(columnID: score.id, comparison: .number, ascending: false)]
        ))

        let grace = try await workspace.search("Grace")
        let hidden = try await workspace.search("Linus")
        let graceIndex = try await workspace.visibleIndex(ofRowID: grace[0].rowID)
        XCTAssertEqual(grace.count, 1)
        XCTAssertTrue(hidden.isEmpty)
        XCTAssertEqual(graceIndex, 0)
    }

    func testReplaceAllIsViewScopedAndSupportsDiskBackedUndoRedo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.csv")
        try Data("name,visible\nAda,yes\nGrace,yes\nLana,no\n".utf8).write(to: source)
        let workspace = try DocumentWorkspace(databaseURL: root.appendingPathComponent("workspace.sqlite"))
        _ = try await workspace.importCSV(from: source, dialect: .standard)
        let visible = try await workspace.columns()[1]
        try await workspace.applyView(ViewDefinition(filters: [
            FilterRule(columnID: visible.id, operation: .equals, value: "yes")
        ]))

        let result = try await workspace.replaceAll(
            "a",
            replacement: "X",
            options: SearchOptions(caseSensitive: true)
        )
        XCTAssertEqual(result.replacementCount, 2)
        let snapshotID = try XCTUnwrap(result.snapshotID)
        try await workspace.applyView(.documentOrder)
        var page = try await workspace.page(offset: 0, limit: 10)
        XCTAssertEqual(page.rows.map { $0.values[0] }, ["AdX", "GrXce", "Lana"])

        let redoSnapshotID = try await workspace.restoreReplacement(snapshotID: snapshotID)
        page = try await workspace.page(offset: 0, limit: 10)
        XCTAssertEqual(page.rows.map { $0.values[0] }, ["Ada", "Grace", "Lana"])

        _ = try await workspace.restoreReplacement(snapshotID: redoSnapshotID)
        page = try await workspace.page(offset: 0, limit: 10)
        XCTAssertEqual(page.rows.map { $0.values[0] }, ["AdX", "GrXce", "Lana"])
    }

    func testInvalidViewDefinitionDoesNotDestroyTheCurrentView() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.csv")
        try Data("name\nAda\nGrace\n".utf8).write(to: source)
        let workspace = try DocumentWorkspace(databaseURL: root.appendingPathComponent("workspace.sqlite"))
        _ = try await workspace.importCSV(from: source, dialect: .standard)
        let name = try await workspace.columns()[0]
        let valid = ViewDefinition(filters: [FilterRule(columnID: name.id, operation: .contains, value: "Ada")])
        try await workspace.applyView(valid)

        let invalid = ViewDefinition(filters: [FilterRule(columnID: name.id, operation: .regex, value: "[")])
        do {
            try await workspace.applyView(invalid)
            XCTFail("Expected invalid regular expression to fail")
        } catch {
            // Expected.
        }
        let page = try await workspace.page(offset: 0, limit: 10)
        let preservedDefinition = await workspace.currentViewDefinition()
        XCTAssertEqual(page.rows.map { $0.values[0] }, ["Ada"])
        XCTAssertEqual(preservedDefinition, valid)
    }

    func testInsertDeleteAndRestoreRowsPreservesDocumentOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.csv")
        try Data("value\nA\nC\n".utf8).write(to: source)
        let workspace = try DocumentWorkspace(databaseURL: root.appendingPathComponent("workspace.sqlite"))
        _ = try await workspace.importCSV(from: source, dialect: .standard)
        let original = try await workspace.page(offset: 0, limit: 10)

        let inserted = try await workspace.insertRows([["B"]], relativeTo: original.rows[0].id, after: true)
        let afterInsert = try await workspace.page(offset: 0, limit: 10)
        XCTAssertEqual(afterInsert.rows.map(\.values), [["A"], ["B"], ["C"]])
        let removed = try await workspace.deleteRows(ids: inserted.map(\.id))
        XCTAssertEqual(removed, inserted)
        try await workspace.restoreRows(removed)
        let restored = try await workspace.page(offset: 0, limit: 10)
        XCTAssertEqual(restored.rows.map(\.values), [["A"], ["B"], ["C"]])
    }

    func testInsertDuplicateDeleteAndRestoreColumns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.csv")
        try Data("first,last\nAda,Lovelace\n".utf8).write(to: source)
        let workspace = try DocumentWorkspace(databaseURL: root.appendingPathComponent("workspace.sqlite"))
        _ = try await workspace.importCSV(from: source, dialect: .standard)

        let inserted = try await workspace.insertColumn(at: 1, name: "middle")
        var columns = try await workspace.columns()
        XCTAssertEqual(columns.map(\.name), ["first", "middle", "last"])
        var row = try await workspace.page(offset: 0, limit: 1).rows[0]
        XCTAssertEqual(row.values, ["Ada", "", "Lovelace"])

        let duplicate = try await workspace.duplicateColumn(id: inserted.id)
        XCTAssertEqual(duplicate.ordinal, 2)
        columns = try await workspace.columns()
        XCTAssertEqual(columns.map(\.name), ["first", "middle", "middle Copy", "last"])

        let snapshot = try await workspace.deleteColumn(id: inserted.id)
        XCTAssertTrue(snapshot.cells.isEmpty)
        XCTAssertNotNil(snapshot.storageID)
        columns = try await workspace.columns()
        XCTAssertEqual(columns.map(\.name), ["first", "middle Copy", "last"])
        _ = try await workspace.restoreColumn(snapshot)
        columns = try await workspace.columns()
        XCTAssertEqual(columns.map(\.name), ["first", "middle", "middle Copy", "last"])
        row = try await workspace.page(offset: 0, limit: 1).rows[0]
        XCTAssertEqual(row.values, ["Ada", "", "", "Lovelace"])
    }

    func testDiskBackedColumnUndoPreservesEmbeddedNulls() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try DocumentWorkspace(databaseURL: root.appendingPathComponent("workspace.sqlite"))
        try await workspace.initializeNewDocument(columns: 2)
        let row = try await workspace.page(offset: 0, limit: 1).rows[0]
        _ = try await workspace.updateCell(rowID: row.id, columnOrdinal: 1, value: "before\0after")
        let column = try await workspace.columns()[1]

        let snapshot = try await workspace.deleteColumn(id: column.id)
        XCTAssertTrue(snapshot.cells.isEmpty)
        XCTAssertNotNil(snapshot.storageID)
        _ = try await workspace.restoreColumn(snapshot)

        let restored = try await workspace.page(offset: 0, limit: 1).rows[0]
        XCTAssertEqual(restored.values[1], "before\0after")
    }

    func testCancelledColumnDeletionLeavesDocumentUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try DocumentWorkspace(databaseURL: root.appendingPathComponent("workspace.sqlite"))
        try await workspace.initializeNewDocument(columns: 2)
        let column = try await workspace.columns()[1]

        let deletion = Task { try await workspace.deleteColumn(id: column.id) }
        deletion.cancel()
        do {
            _ = try await deletion.value
            XCTFail("Expected column deletion cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let remainingColumns = try await workspace.columns()
        let remainingRow = try await workspace.page(offset: 0, limit: 1).rows[0]
        XCTAssertEqual(remainingColumns.count, 2)
        XCTAssertEqual(remainingRow.values.count, 2)
    }

    func testCancellingViewProjectionInterruptsSQLiteAndRollsBack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("large.csv")
        let body = (0..<20_000).map { "row-\($0),\($0)" }.joined(separator: "\n")
        try Data(("name,value\n" + body + "\n").utf8).write(to: source)
        let workspace = try DocumentWorkspace(databaseURL: root.appendingPathComponent("workspace.sqlite"))
        _ = try await workspace.importCSV(from: source, dialect: .standard)
        let valueColumn = try await workspace.columns()[1]

        let projection = Task {
            try await workspace.applyView(ViewDefinition(filters: [
                FilterRule(columnID: valueColumn.id, comparison: .number, operation: .greaterThan, value: "50000")
            ]))
        }
        try await Task.sleep(for: .milliseconds(2))
        projection.cancel()
        do {
            try await projection.value
            XCTFail("Expected view projection cancellation")
        } catch is CancellationError {
            // Expected: SQLite's progress handler translates SQLITE_INTERRUPT back to task cancellation.
        }

        let hasActiveView = await workspace.hasActiveView()
        let rowCount = try await workspace.rowCount()
        XCTAssertFalse(hasActiveView)
        XCTAssertEqual(rowCount, 20_000)
        try await workspace.applyView(ViewDefinition(filters: [
            FilterRule(columnID: valueColumn.id, comparison: .number, operation: .greaterThan, value: "19998")
        ]))
        let finalPage = try await workspace.page(offset: 0, limit: 10)
        XCTAssertEqual(finalPage.rows.map { $0.values[0] }, ["row-19999"])
    }

    func testVisibleRangeReadAndDeleteDoesNotDependOnPageCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.csv")
        let body = (0..<1_000).map { "\($0),value-\($0)" }.joined(separator: "\n")
        try Data(("id,value\n" + body + "\n").utf8).write(to: source)
        let workspace = try DocumentWorkspace(databaseURL: root.appendingPathComponent("workspace.sqlite"))
        _ = try await workspace.importCSV(from: source, dialect: .standard)

        let selected = try await workspace.rows(inVisibleRanges: [700..<703, 900..<902])
        XCTAssertEqual(selected.map { $0.values[0] }, ["700", "701", "702", "900", "901"])
        let removed = try await workspace.deleteRows(inVisibleRanges: [700..<703, 900..<902])
        XCTAssertEqual(removed.map { $0.values[0] }, ["700", "701", "702", "900", "901"])
        let remaining = try await workspace.rowCount()
        XCTAssertEqual(remaining, 995)
    }

    func testDiskBackedRowDeleteUndoPreservesAFilteredSortedSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.csv")
        let body = (0..<1_000).map { "\($0),value-\($0)" }.joined(separator: "\n")
        try Data(("id,value\n" + body + "\n").utf8).write(to: source)
        let workspace = try DocumentWorkspace(databaseURL: root.appendingPathComponent("workspace.sqlite"))
        _ = try await workspace.importCSV(from: source, dialect: .standard)
        let idColumn = try await workspace.columns()[0]
        try await workspace.applyView(ViewDefinition(
            filters: [FilterRule(columnID: idColumn.id, comparison: .number, operation: .greaterThan, value: "500")],
            sorts: [SortRule(columnID: idColumn.id, comparison: .number, ascending: false)]
        ))

        let snapshot = try await workspace.deleteRowsToSnapshot(inVisibleRanges: [0..<3, 10..<12])
        XCTAssertEqual(snapshot.count, 5)
        var visibleCount = try await workspace.rowCount()
        XCTAssertEqual(visibleCount, 494)

        try await workspace.restoreRows(from: snapshot)
        var page = try await workspace.page(offset: 0, limit: 12)
        XCTAssertEqual(page.rows.map { $0.values[0] }, (988...999).reversed().map(String.init))

        try await workspace.removeRows(in: snapshot)
        visibleCount = try await workspace.rowCount()
        XCTAssertEqual(visibleCount, 494)
        try await workspace.restoreRows(from: snapshot)
        page = try await workspace.page(offset: 0, limit: 3)
        XCTAssertEqual(page.rows.map { $0.values[0] }, ["999", "998", "997"])
    }

    func testSequentialDocumentPagesUseCorrectOffsetsAndInvalidateAfterMutation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.csv")
        let body = (0..<1_000).map { "\($0),value-\($0)" }.joined(separator: "\n")
        try Data(("id,value\n" + body + "\n").utf8).write(to: source)
        let workspace = try DocumentWorkspace(databaseURL: root.appendingPathComponent("workspace.sqlite"))
        _ = try await workspace.importCSV(from: source, dialect: .standard)

        let distant = try await workspace.page(offset: 700, limit: 10)
        let adjacent = try await workspace.page(offset: 710, limit: 10)
        XCTAssertEqual(distant.rows.map { $0.values[0] }, (700..<710).map(String.init))
        XCTAssertEqual(adjacent.rows.map { $0.values[0] }, (710..<720).map(String.init))

        let first = try await workspace.page(offset: 0, limit: 1).rows[0]
        _ = try await workspace.deleteRows(ids: [first.id])
        let shifted = try await workspace.page(offset: 710, limit: 10)
        XCTAssertEqual(shifted.rows.map { $0.values[0] }, (711..<721).map(String.init))
    }

    func testPasteInsertsRowsGrowsColumnsAndRoundTripsUndoSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.csv")
        try Data("name\nExisting\nAfter\n".utf8).write(to: source)
        let workspace = try DocumentWorkspace(databaseURL: root.appendingPathComponent("workspace.sqlite"))
        _ = try await workspace.importCSV(from: source, dialect: .standard)
        let first = try await workspace.page(offset: 0, limit: 1).rows[0]

        let paste = try await workspace.insertPastedRows(
            [["Ada", "Lovelace"], ["Grace", "Hopper"]],
            startingColumn: 1,
            relativeTo: first.id
        )
        var columns = try await workspace.columns()
        var rows = try await workspace.page(offset: 0, limit: 10)
        XCTAssertEqual(columns.count, 3)
        XCTAssertEqual(rows.rows.map { row in
            row.values + Array(repeating: "", count: max(0, columns.count - row.values.count))
        }, [
            ["Existing", "", ""], ["", "Ada", "Lovelace"], ["", "Grace", "Hopper"], ["After", "", ""]
        ])

        try await workspace.removePaste(paste)
        columns = try await workspace.columns()
        rows = try await workspace.page(offset: 0, limit: 10)
        XCTAssertEqual(columns.count, 1)
        XCTAssertEqual(rows.rows.map(\.values), [["Existing"], ["After"]])

        try await workspace.restorePaste(paste)
        columns = try await workspace.columns()
        rows = try await workspace.page(offset: 0, limit: 10)
        XCTAssertEqual(columns.count, 3)
        XCTAssertEqual(rows.rows.map { row in
            row.values + Array(repeating: "", count: max(0, columns.count - row.values.count))
        }, [
            ["Existing", "", ""], ["", "Ada", "Lovelace"], ["", "Grace", "Hopper"], ["After", "", ""]
        ])
    }

    func testMoveRowsAndRestorePreviousOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.csv")
        try Data("value\nA\nB\nC\nD\n".utf8).write(to: source)
        let workspace = try DocumentWorkspace(databaseURL: root.appendingPathComponent("workspace.sqlite"))
        _ = try await workspace.importCSV(from: source, dialect: .standard)
        let original = try await workspace.page(offset: 0, limit: 10)

        let previousOrder = try await workspace.moveRows(
            ids: [original.rows[1].id, original.rows[2].id],
            beforeRowID: original.rows[0].id
        )
        var rows = try await workspace.page(offset: 0, limit: 10)
        XCTAssertEqual(rows.rows.map { $0.values[0] }, ["B", "C", "A", "D"])
        _ = try await workspace.reorderRows(idsInDocumentOrder: previousOrder)
        rows = try await workspace.page(offset: 0, limit: 10)
        XCTAssertEqual(rows.rows.map { $0.values[0] }, ["A", "B", "C", "D"])
    }

    func testMultiColumnDeleteCapturesLosslessSnapshots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.csv")
        try Data("a,b,c,d\n1,2,3,4\n5,6,7,8\n".utf8).write(to: source)
        let workspace = try DocumentWorkspace(databaseURL: root.appendingPathComponent("workspace.sqlite"))
        _ = try await workspace.importCSV(from: source, dialect: .standard)
        let original = try await workspace.columns()

        let snapshots = try await workspace.deleteColumns(ids: [original[1].id, original[3].id])
        var columns = try await workspace.columns()
        var rows = try await workspace.page(offset: 0, limit: 10)
        XCTAssertEqual(columns.map(\.name), ["a", "c"])
        XCTAssertEqual(rows.rows.map(\.values), [["1", "3"], ["5", "7"]])
        for snapshot in snapshots.sorted(by: { $0.ordinal < $1.ordinal }) {
            _ = try await workspace.restoreColumn(snapshot)
        }
        columns = try await workspace.columns()
        rows = try await workspace.page(offset: 0, limit: 10)
        XCTAssertEqual(columns.map(\.name), ["a", "b", "c", "d"])
        XCTAssertEqual(rows.rows.map(\.values), [["1", "2", "3", "4"], ["5", "6", "7", "8"]])
    }
}
