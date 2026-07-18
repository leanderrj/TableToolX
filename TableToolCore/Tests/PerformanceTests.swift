import Foundation
import XCTest
@testable import TableToolCore

final class PerformanceTests: XCTestCase {
    func testLargeFileBudgets() async throws {
        guard let requestedMB = ProcessInfo.processInfo.environment["TABLETOOLX_PERFORMANCE_MB"].flatMap(Int.init) else {
            throw XCTSkip("Set TABLETOOLX_PERFORMANCE_MB to run the large-file performance test.")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableToolX-Performance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("benchmark.csv")
        FileManager.default.createFile(atPath: source.path, contents: Data("id,sku,name,amount,date,notes\n".utf8))
        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd()
        let targetBytes = Int64(requestedMB) * 1_024 * 1_024
        var row: Int64 = 0
        while try handle.offset() < UInt64(targetBytes) {
            var batch = String()
            for _ in 0..<2_000 {
                batch += "\(row),SKU-\(String(format: "%010lld", row)),Widget \(row % 997),\(row % 10_000).\(String(format: "%02lld", row % 100)),2026-07-18,\"generated row \(row)\"\n"
                row += 1
            }
            try handle.write(contentsOf: Data(batch.utf8))
        }
        try handle.close()

        let clock = ContinuousClock()
        let workspace = try DocumentWorkspace(databaseURL: root.appendingPathComponent("workspace.sqlite"))
        let importStart = clock.now
        _ = try await workspace.importCSV(from: source, dialect: .standard)
        let importSeconds = seconds(importStart.duration(to: clock.now))
        let count = try await workspace.rowCount()

        let tailStart = clock.now
        _ = try await workspace.page(offset: max(0, count - 256), limit: 256)
        let tailMilliseconds = seconds(tailStart.duration(to: clock.now)) * 1_000
        let middleOffset = max(0, count / 2)
        _ = try await workspace.page(offset: middleOffset, limit: 256)
        let adjacentStart = clock.now
        _ = try await workspace.page(offset: middleOffset + 256, limit: 256)
        let adjacentMilliseconds = seconds(adjacentStart.duration(to: clock.now)) * 1_000

        let columns = try await workspace.columns()
        let filterStart = clock.now
        try await workspace.applyView(ViewDefinition(filters: [
            FilterRule(columnID: columns[3].id, comparison: .number, operation: .greaterThan, value: "5000")
        ]))
        let filterSeconds = seconds(filterStart.duration(to: clock.now))
        let filteredRow = try await workspace.page(offset: 0, limit: 1).rows[0]
        let editStart = clock.now
        _ = try await workspace.updateCell(rowID: filteredRow.id, columnOrdinal: 2, value: "Edited without rebuilding the view")
        let editMilliseconds = seconds(editStart.duration(to: clock.now)) * 1_000

        try await workspace.applyView(.documentOrder)
        let sortStart = clock.now
        try await workspace.applyView(ViewDefinition(sorts: [
            SortRule(columnID: columns[3].id, comparison: .number, ascending: false)
        ]))
        let sortSeconds = seconds(sortStart.duration(to: clock.now))
        try await workspace.applyView(.documentOrder)

        let firstRow = try await workspace.page(offset: 0, limit: 1).rows[0]
        let pasteStart = clock.now
        let paste = try await workspace.insertPastedRows([["new column"]], startingColumn: columns.count, relativeTo: firstRow.id)
        try await workspace.removePaste(paste)
        let pasteMilliseconds = seconds(pasteStart.duration(to: clock.now)) * 1_000

        let deleteRowsStart = clock.now
        let deletedRows = try await workspace.deleteRowsToSnapshot(inVisibleRanges: [0..<min(count / 10, 100_000)])
        try await workspace.restoreRows(from: deletedRows)
        let deleteRowsSeconds = seconds(deleteRowsStart.duration(to: clock.now))

        let duplicateStart = clock.now
        let duplicate = try await workspace.duplicateColumn(id: columns[0].id)
        let duplicateSeconds = seconds(duplicateStart.duration(to: clock.now))
        let deleteColumnStart = clock.now
        _ = try await workspace.deleteColumn(id: duplicate.id)
        let deleteColumnSeconds = seconds(deleteColumnStart.duration(to: clock.now))

        let exportStart = clock.now
        try await workspace.export(to: root.appendingPathComponent("export.csv"))
        let exportSeconds = seconds(exportStart.duration(to: clock.now))

        print("dataset_mb=\(requestedMB)")
        print("rows=\(count)")
        print("import_seconds=\(importSeconds)")
        print("export_seconds=\(exportSeconds)")
        print("cold_tail_page_ms=\(tailMilliseconds)")
        print("warm_adjacent_page_ms=\(adjacentMilliseconds)")
        print("numeric_filter_seconds=\(filterSeconds)")
        print("unrelated_view_cell_edit_ms=\(editMilliseconds)")
        print("cached_numeric_sort_seconds=\(sortSeconds)")
        print("paste_grow_round_trip_ms=\(pasteMilliseconds)")
        print("row_delete_undo_seconds=\(deleteRowsSeconds)")
        print("duplicate_column_seconds=\(duplicateSeconds)")
        print("delete_column_seconds=\(deleteColumnSeconds)")

        XCTAssertGreaterThan(count, 0)
        XCTAssertGreaterThan(importSeconds, 0)
        XCTAssertLessThanOrEqual(importSeconds, 120)
        XCTAssertGreaterThan(exportSeconds, 0)
        XCTAssertLessThanOrEqual(exportSeconds, 120)
        XCTAssertLessThanOrEqual(tailMilliseconds, 1_000)
        XCTAssertLessThanOrEqual(adjacentMilliseconds, 100)
        XCTAssertGreaterThan(filterSeconds, 0)
        XCTAssertLessThanOrEqual(filterSeconds, 120)
        XCTAssertLessThanOrEqual(editMilliseconds, 1_000)
        XCTAssertGreaterThan(sortSeconds, 0)
        XCTAssertLessThanOrEqual(sortSeconds, 120)
        XCTAssertLessThanOrEqual(pasteMilliseconds, 2_000)
        XCTAssertGreaterThan(deleteRowsSeconds, 0)
        XCTAssertLessThanOrEqual(deleteRowsSeconds, 120)
        XCTAssertGreaterThan(duplicateSeconds, 0)
        XCTAssertLessThanOrEqual(duplicateSeconds, 120)
        XCTAssertGreaterThan(deleteColumnSeconds, 0)
        XCTAssertLessThanOrEqual(deleteColumnSeconds, 120)
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
