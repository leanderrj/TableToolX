import AppKit
import Combine
import SwiftUI
import TableToolCore

struct DataGridView: NSViewRepresentable {
    @ObservedObject var viewModel: DocumentViewModel

    func makeCoordinator() -> Coordinator { Coordinator(viewModel: viewModel) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = DataGridTableView()
        table.gridDelegate = context.coordinator
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        table.allowsMultipleSelection = true
        table.allowsColumnSelection = true
        table.allowsColumnReordering = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 1, height: 1)
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.beginEditing(_:))
        let header = DataGridHeaderView()
        header.gridDelegate = context.coordinator
        table.headerView = header
        table.registerForDraggedTypes([.tableToolRows])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setAccessibilityLabel("Delimited data grid")

        let contextMenu = NSMenu(title: "Table")
        contextMenu.addItem(withTitle: "Insert Row Above", action: #selector(Coordinator.insertRowAbove(_:)), keyEquivalent: "")
        contextMenu.addItem(withTitle: "Insert Row Below", action: #selector(Coordinator.insertRowBelow(_:)), keyEquivalent: "")
        contextMenu.addItem(withTitle: "Delete Selected Rows", action: #selector(Coordinator.deleteRows(_:)), keyEquivalent: "")
        contextMenu.addItem(.separator())
        contextMenu.addItem(withTitle: "Insert Column Left", action: #selector(Coordinator.insertColumnLeft(_:)), keyEquivalent: "")
        contextMenu.addItem(withTitle: "Insert Column Right", action: #selector(Coordinator.insertColumnRight(_:)), keyEquivalent: "")
        contextMenu.addItem(withTitle: "Delete Selected Columns", action: #selector(Coordinator.deleteColumns(_:)), keyEquivalent: "")
        for item in contextMenu.items { item.target = context.coordinator }
        table.menu = contextMenu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        context.coordinator.tableView = table
        context.coordinator.rebuildColumns()
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.synchronizeStructure()
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, DataGridActionDelegate {
        let viewModel: DocumentViewModel
        weak var tableView: NSTableView?
        private var cancellables = Set<AnyCancellable>()

        init(viewModel: DocumentViewModel) {
            self.viewModel = viewModel
            super.init()
            viewModel.$columns.sink { [weak self] _ in self?.rebuildColumns() }.store(in: &cancellables)
            Publishers.CombineLatest(viewModel.$activeSortColumnID, viewModel.$activeSortAscending)
                .sink { [weak self] _, _ in self?.updateSortIndicators() }
                .store(in: &cancellables)
            NotificationCenter.default.publisher(for: .tableToolRevealCell, object: viewModel).sink { [weak self] note in
                guard let row = note.userInfo?["row"] as? Int64, let column = note.userInfo?["column"] as? Int else { return }
                self?.reveal(row: row, column: column)
            }.store(in: &cancellables)
            NotificationCenter.default.publisher(for: .tableToolRowsReload, object: viewModel).sink { [weak self] note in
                guard let self,
                      let offset = note.userInfo?["offset"] as? Int64,
                      let count = note.userInfo?["count"] as? Int else { return }
                reloadRows(offset: offset, count: count)
            }.store(in: &cancellables)
            NotificationCenter.default.publisher(for: .tableToolGridReload, object: viewModel).sink { [weak self] _ in
                self?.tableView?.reloadData()
            }.store(in: &cancellables)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            Int(clamping: viewModel.totalRowCount)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let ordinal = Int(tableColumn.identifier.rawValue) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("DataCell")
            let field: GridTextField
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? GridTextField {
                field = reused
            } else {
                field = GridTextField()
                field.identifier = identifier
                field.isBordered = false
                field.drawsBackground = false
                field.lineBreakMode = .byTruncatingTail
                field.focusRingType = .none
                field.delegate = self
            }
            if let record = viewModel.row(at: Int64(row)) {
                field.stringValue = ordinal < record.values.count ? record.values[ordinal] : ""
                field.rowID = record.id
                field.columnOrdinal = ordinal
                field.isEditable = viewModel.phase.isInteractive
                field.toolTip = field.stringValue.contains("\n") ? field.stringValue : nil
                field.setAccessibilityLabel("\(viewModel.columns[ordinal].name), row \(row + 1)")
            } else {
                field.stringValue = "Loading…"
                field.rowID = nil
                field.isEditable = false
            }
            return field
        }

        func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
        func tableViewColumnDidMove(_ notification: Notification) {
            guard let table = tableView else { return }
            let ids = table.tableColumns.compactMap { column -> Int64? in
                guard let formerOrdinal = Int(column.identifier.rawValue), formerOrdinal < viewModel.columns.count else { return nil }
                return viewModel.columns[formerOrdinal].id
            }
            if ids.count == viewModel.columns.count { viewModel.reorderColumns(ids: ids) }
            updateSelection()
        }

        func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn columnIndex: Int) -> CGFloat {
            guard columnIndex >= 0, columnIndex < tableView.tableColumns.count,
                  let ordinal = Int(tableView.tableColumns[columnIndex].identifier.rawValue) else { return 160 }
            let tableColumn = tableView.tableColumns[columnIndex]
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
            var widest = (tableColumn.title as NSString).size(withAttributes: attributes).width + 30

            // Cached rows include the visible page and recently visited pages. Measuring
            // them keeps divider auto-fit immediate even for documents with millions of rows.
            for row in viewModel.cachedRows.values where ordinal < row.values.count {
                for line in row.values[ordinal].split(separator: "\n", omittingEmptySubsequences: false) {
                    widest = max(widest, (String(line) as NSString).size(withAttributes: attributes).width + 16)
                }
            }
            return min(tableColumn.maxWidth, max(tableColumn.minWidth, ceil(widest)))
        }

        func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pasteboard: NSPasteboard) -> Bool {
            let rows = rowIndexes.compactMap { viewModel.row(at: Int64($0)) }
            guard rows.count == rowIndexes.count else { return false }
            var clipboardDialect = CSVDialect.tsv
            clipboardDialect.hasHeader = false
            clipboardDialect.hasFinalNewline = false
            guard let data = try? CSVStreamWriter(dialect: clipboardDialect).serialize(rows.map(\.values)),
                  let tabularText = String(data: data, encoding: .utf8) else { return false }
            pasteboard.declareTypes([.tableToolRows, .tabularText, .string], owner: nil)
            let storedRows = pasteboard.setString(rows.map { String($0.id) }.joined(separator: ","), forType: .tableToolRows)
            let storedTabularText = pasteboard.setString(tabularText, forType: .tabularText)
            let storedString = pasteboard.setString(tabularText, forType: .string)
            return storedRows && storedTabularText && storedString
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            tableView.setDropRow(row, dropOperation: .above)
            guard let source = info.draggingSource as? NSTableView, source === tableView else { return [] }
            return .move
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            guard let text = info.draggingPasteboard.string(forType: .tableToolRows) else { return false }
            let ids = text.split(separator: ",").compactMap { Int64($0) }
            guard !ids.isEmpty else { return false }
            viewModel.moveRows(ids: ids, beforeVisibleRow: Int64(row))
            return true
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? GridTextField, let rowID = field.rowID else { return }
            viewModel.edit(rowID: rowID, columnOrdinal: field.columnOrdinal, value: field.stringValue)
        }

        @objc func beginEditing(_ sender: Any?) {
            guard let table = tableView, table.clickedRow >= 0, table.clickedColumn >= 0 else { return }
            table.editColumn(table.clickedColumn, row: table.clickedRow, with: nil, select: true)
        }

        @objc func insertRowAbove(_ sender: Any?) {
            selectClickedRowIfNeeded()
            viewModel.addRow(after: false)
        }

        @objc func insertRowBelow(_ sender: Any?) {
            selectClickedRowIfNeeded()
            viewModel.addRow(after: true)
        }

        @objc func deleteRows(_ sender: Any?) {
            selectClickedRowIfNeeded()
            viewModel.deleteSelectedRows()
        }

        @objc func insertColumnLeft(_ sender: Any?) {
            selectClickedColumnIfNeeded()
            viewModel.addColumn(relativeToSelectionAfter: false)
        }

        @objc func insertColumnRight(_ sender: Any?) {
            selectClickedColumnIfNeeded()
            viewModel.addColumn(relativeToSelectionAfter: true)
        }

        @objc func deleteColumns(_ sender: Any?) {
            selectClickedColumnIfNeeded()
            viewModel.deleteSelectedColumn()
        }

        func rebuildColumns() {
            guard let table = tableView else { return }
            let expected = viewModel.columns.map { String($0.ordinal) }
            let current = table.tableColumns.map { $0.identifier.rawValue }
            guard expected != current || zip(table.tableColumns, viewModel.columns).contains(where: { $0.headerCell.stringValue != $1.name }) else { return }
            for column in table.tableColumns { table.removeTableColumn(column) }
            for column in viewModel.columns {
                let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(column.ordinal)))
                tableColumn.title = column.name
                tableColumn.width = 160
                tableColumn.minWidth = 60
                tableColumn.maxWidth = 1_000
                tableColumn.headerToolTip = "Double-click to sort. Double-click a divider to auto-fit."
                table.addTableColumn(tableColumn)
            }
            updateSortIndicators()
            table.reloadData()
        }

        func didDoubleClickHeader(columnIndex: Int) {
            guard let table = tableView,
                  columnIndex >= 0,
                  columnIndex < table.tableColumns.count,
                  let ordinal = Int(table.tableColumns[columnIndex].identifier.rawValue),
                  ordinal < viewModel.columns.count,
                  viewModel.phase.isInteractive,
                  viewModel.activeOperation == nil else { return }
            table.selectColumnIndexes(IndexSet(integer: columnIndex), byExtendingSelection: false)
            updateSelection()
            viewModel.toggleSortColumn(at: ordinal)
        }

        func synchronizeStructure() {
            guard let table = tableView else { return }
            rebuildColumns()
            if table.numberOfRows != Int(clamping: viewModel.totalRowCount) {
                table.noteNumberOfRowsChanged()
            }
        }

        func copySelection() {
            guard let table = tableView else { return }
            let rows: IndexSet
            let columns: IndexSet
            if !table.selectedRowIndexes.isEmpty {
                rows = table.selectedRowIndexes
                columns = IndexSet(integersIn: 0..<viewModel.columns.count)
            } else if !table.selectedColumnIndexes.isEmpty {
                rows = IndexSet(integersIn: 0..<Int(clamping: viewModel.totalRowCount))
                columns = table.selectedColumnIndexes
            } else if table.clickedRow >= 0 {
                rows = IndexSet(integer: table.clickedRow)
                columns = IndexSet(integersIn: 0..<viewModel.columns.count)
            } else if table.clickedColumn >= 0 {
                rows = IndexSet(integersIn: 0..<Int(clamping: viewModel.totalRowCount))
                columns = IndexSet(integer: table.clickedColumn)
            } else {
                NSSound.beep()
                return
            }
            viewModel.copyRows(rows, columns: columns)
        }

        func pasteSelection() {
            guard let table = tableView, let text = NSPasteboard.general.string(forType: .string) else { return }
            let row = table.selectedRowIndexes.last.map(Int64.init)
            viewModel.paste(text, afterVisibleRow: row)
        }

        func deleteSelection() {
            guard let table = tableView else { return }
            if !table.selectedRowIndexes.isEmpty {
                viewModel.deleteSelectedRows()
            } else if !table.selectedColumnIndexes.isEmpty {
                viewModel.deleteSelectedColumn()
            } else {
                NSSound.beep()
            }
        }

        func canPerformGridAction(_ action: Selector) -> Bool {
            guard let table = tableView,
                  viewModel.phase.isInteractive,
                  viewModel.activeOperation == nil else { return false }
            switch action {
            case #selector(DataGridTableView.copy(_:)):
                return !table.selectedRowIndexes.isEmpty || !table.selectedColumnIndexes.isEmpty
            case #selector(DataGridTableView.paste(_:)):
                return NSPasteboard.general.string(forType: .string) != nil
            case #selector(DataGridTableView.delete(_:)):
                if !table.selectedRowIndexes.isEmpty { return true }
                return !table.selectedColumnIndexes.isEmpty
                    && table.selectedColumnIndexes.count < viewModel.columns.count
            default:
                return true
            }
        }

        private func updateSelection() {
            guard let table = tableView else { return }
            viewModel.selectedColumnOrdinals = table.selectedColumnIndexes
            viewModel.selectedRowIndexes = table.selectedRowIndexes
            viewModel.selectedRowIDs = Set(table.selectedRowIndexes.compactMap { viewModel.row(at: Int64($0))?.id })
        }

        private func selectClickedRowIfNeeded() {
            guard let table = tableView, table.clickedRow >= 0 else { return }
            if !table.selectedRowIndexes.contains(table.clickedRow) {
                table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
            }
            updateSelection()
        }

        private func selectClickedColumnIfNeeded() {
            guard let table = tableView, table.clickedColumn >= 0 else { return }
            if !table.selectedColumnIndexes.contains(table.clickedColumn) {
                table.selectColumnIndexes(IndexSet(integer: table.clickedColumn), byExtendingSelection: false)
            }
            updateSelection()
        }

        private func reveal(row: Int64, column: Int) {
            guard let table = tableView else { return }
            let rowIndex = Int(clamping: row)
            table.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
            if column < table.numberOfColumns { table.selectColumnIndexes(IndexSet(integer: column), byExtendingSelection: false) }
            table.scrollRowToVisible(rowIndex)
            if column < table.numberOfColumns { table.scrollColumnToVisible(column) }
        }

        private func reloadRows(offset: Int64, count: Int) {
            guard let table = tableView, count > 0, table.numberOfColumns > 0 else { return }
            let lower = max(0, Int(clamping: offset))
            let upper = min(table.numberOfRows, lower + count)
            guard lower < upper else { return }
            table.reloadData(
                forRowIndexes: IndexSet(integersIn: lower..<upper),
                columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns)
            )
        }

        private func updateSortIndicators() {
            guard let table = tableView else { return }
            for tableColumn in table.tableColumns {
                guard let ordinal = Int(tableColumn.identifier.rawValue), ordinal < viewModel.columns.count else { continue }
                let columnID = viewModel.columns[ordinal].id
                let image: NSImage?
                if columnID == viewModel.activeSortColumnID {
                    let symbol = viewModel.activeSortAscending ? "chevron.up" : "chevron.down"
                    image = NSImage(systemSymbolName: symbol, accessibilityDescription: viewModel.activeSortAscending ? "Ascending" : "Descending")
                } else {
                    image = nil
                }
                table.setIndicatorImage(image, in: tableColumn)
            }
        }
    }
}

private extension NSPasteboard.PasteboardType {
    static let tableToolRows = NSPasteboard.PasteboardType("com.leanderrj.TableToolX.rows")
}

private final class GridTextField: NSTextField {
    var rowID: Int64?
    var columnOrdinal = 0
}

@MainActor
private protocol DataGridActionDelegate: AnyObject {
    func copySelection()
    func pasteSelection()
    func deleteSelection()
    func canPerformGridAction(_ action: Selector) -> Bool
    func didDoubleClickHeader(columnIndex: Int)
}

private final class DataGridHeaderView: NSTableHeaderView {
    weak var gridDelegate: DataGridActionDelegate?

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let columnIndex = column(at: location)
        let isResizeGesture = isNearColumnDivider(location.x)
        super.mouseDown(with: event)
        if event.clickCount == 2, columnIndex >= 0, !isResizeGesture {
            gridDelegate?.didDoubleClickHeader(columnIndex: columnIndex)
        }
    }

    private func isNearColumnDivider(_ x: CGFloat) -> Bool {
        guard let tableView else { return false }
        for index in 0..<tableView.numberOfColumns {
            if abs(headerRect(ofColumn: index).maxX - x) <= 4 { return true }
        }
        return false
    }
}

private final class DataGridTableView: NSTableView {
    weak var gridDelegate: DataGridActionDelegate?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // NSTableView expands to the viewport and otherwise continues drawing row
        // separators through the unused area to the right of the final column.
        // Mask that area so the data grid has an unambiguous trailing edge.
        let tableContentWidth = tableColumns.last.map { _ in rect(ofColumn: numberOfColumns - 1).maxX } ?? 0
        guard tableContentWidth < bounds.maxX else { return }

        let unusedRect = NSRect(
            x: tableContentWidth,
            y: bounds.minY,
            width: bounds.maxX - tableContentWidth,
            height: bounds.height
        ).intersection(dirtyRect)
        guard !unusedRect.isEmpty else { return }

        NSColor.controlBackgroundColor.setFill()
        unusedRect.fill()

        if dirtyRect.minX <= tableContentWidth, dirtyRect.maxX >= tableContentWidth {
            NSColor.separatorColor.setFill()
            NSRect(x: tableContentWidth, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
        }
    }

    @objc func copy(_ sender: Any?) { gridDelegate?.copySelection() }
    @objc func paste(_ sender: Any?) { gridDelegate?.pasteSelection() }
    @objc func delete(_ sender: Any?) { gridDelegate?.deleteSelection() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let action = item.action else { return false }
        if action == #selector(copy(_:)) || action == #selector(paste(_:)) || action == #selector(delete(_:)) {
            return gridDelegate?.canPerformGridAction(action) ?? false
        }
        return super.validateUserInterfaceItem(item)
    }
}
