import AppKit
import Combine
import Foundation
import TableToolCore

@MainActor
final class DocumentViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case importing(Double, Int64)
        case cancelled
        case ready
        case failed(String)

        var isInteractive: Bool {
            if case .ready = self { true } else { false }
        }

        var allowsFormatChanges: Bool {
            switch self {
            case .ready, .failed, .cancelled: true
            default: false
            }
        }

        var requiresReimport: Bool {
            switch self {
            case .failed, .cancelled: true
            default: false
            }
        }
    }

    let workspace: DocumentWorkspace
    weak var document: TableDocument?

    @Published var columns: [WorkspaceColumn] = []
    @Published var totalRowCount: Int64 = 0
    @Published var phase: Phase = .idle
    @Published var warningCount = 0
    @Published var dialect: CSVDialect = .standard
    @Published var isFindVisible = false
    @Published var findText = ""
    @Published var replaceText = ""
    @Published var findUsesRegex = false
    @Published var findIsCaseSensitive = false
    @Published var searchMatches: [SearchMatch] = []
    @Published var activeMatchIndex = 0
    @Published var selectedRowIDs = Set<Int64>()
    @Published var selectedRowIndexes = IndexSet()
    @Published var selectedColumnOrdinals = IndexSet()
    @Published var filterColumnID: Int64?
    @Published var filterComparison: ColumnComparison = .text
    @Published var filterOperation: FilterOperator = .contains
    @Published var filterValue = ""
    @Published var sortComparison: ColumnComparison = .text
    @Published private(set) var activeSortColumnID: Int64?
    @Published private(set) var activeSortAscending = true
    @Published var statusMessage = "Ready"
    @Published private(set) var activeOperation: String?

    private(set) var cachedRows: [Int64: WorkspaceRow] = [:]
    private var rowIndexByID: [Int64: Int64] = [:]
    private var cachedPageOffsets: [Int64] = []
    private var pendingPageTasks: [Int64: Task<Void, Never>] = [:]
    private var trackedTasks: [UUID: Task<Void, Never>] = [:]
    private var activeOperationTaskID: UUID?
    private var documentTask: Task<Void, Never>?
    private var documentTaskGeneration = 0
    private let pageSize: Int64 = 256
    private let maximumCachedPageCount = 8
    private var sourceURL: URL?
    private var activeFilters: [FilterRule] = []
    private var activeSorts: [SortRule] = []

    init(workspace: DocumentWorkspace) {
        self.workspace = workspace
    }

    func createNew() {
        let generation = beginDocumentTask()
        phase = .importing(0, 0)
        documentTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await workspace.initializeNewDocument()
                try Task.checkCancellation()
                guard generation == documentTaskGeneration else { return }
                dialect = await workspace.currentDialect()
                try await reloadMetadataAndFirstPage()
                guard generation == documentTaskGeneration else { return }
                phase = .ready
                statusMessage = "1 row × 3 columns"
                documentTask = nil
            } catch is CancellationError {
                finishCancelledDocumentTask(generation: generation)
            } catch {
                guard generation == documentTaskGeneration else { return }
                documentTask = nil
                fail(error)
            }
        }
    }

    func restoreExisting(sourceURL: URL? = nil) {
        self.sourceURL = sourceURL
        let generation = beginDocumentTask()
        phase = .importing(0, 0)
        documentTask = Task { [weak self] in
            guard let self else { return }
            do {
                dialect = await workspace.currentDialect()
                try await reloadMetadataAndFirstPage()
                try Task.checkCancellation()
                guard generation == documentTaskGeneration else { return }
                phase = .ready
                statusMessage = "Recovered unsaved document — \(totalRowCount.formatted()) rows"
                documentTask = nil
            } catch is CancellationError {
                finishCancelledDocumentTask(generation: generation)
            } catch {
                guard generation == documentTaskGeneration else { return }
                documentTask = nil
                fail(error)
            }
        }
    }

    func open(
        _ url: URL,
        dialect requestedDialect: CSVDialect? = nil,
        recoveryPolicy: CSVRecoveryPolicy = .strict
    ) {
        let generation = beginDocumentTask()
        sourceURL = url
        warningCount = 0
        phase = .importing(0, 0)
        statusMessage = recoveryPolicy == .bestEffort
            ? "Indexing with best-effort recovery…"
            : (requestedDialect == nil ? "Detecting format…" : "Indexing…")
        documentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let dialect: CSVDialect
                if let requestedDialect {
                    dialect = requestedDialect
                } else {
                    dialect = try await Task.detached(priority: .userInitiated) {
                        try CSVDialectDetector.detect(fileURL: url).dialect
                    }.value
                }
                try Task.checkCancellation()
                guard generation == documentTaskGeneration else { return }
                self.dialect = dialect
                statusMessage = recoveryPolicy == .bestEffort ? "Indexing with best-effort recovery…" : "Indexing…"
                let importResult = try await workspace.importCSV(
                    from: url,
                    dialect: dialect,
                    recoveryPolicy: recoveryPolicy,
                    progress: { progress in
                        Task { @MainActor in
                            guard generation == self.documentTaskGeneration else { return }
                            let fraction = progress.totalBytes > 0 ? Double(progress.bytesRead) / Double(progress.totalBytes) : 0
                            self.phase = .importing(fraction, progress.rowsImported)
                            self.statusMessage = "Indexing \(progress.rowsImported.formatted()) rows…"
                            self.totalRowCount = progress.rowsImported
                            if self.columns.isEmpty, progress.maximumColumnCount > 0 {
                                self.columns = (0..<progress.maximumColumnCount).map { ordinal in
                                    let proposed = progress.header.flatMap { ordinal < $0.count ? $0[ordinal] : nil }
                                    let name = proposed.flatMap { $0.isEmpty ? nil : $0 } ?? self.previewColumnName(ordinal)
                                    return WorkspaceColumn(id: -Int64(ordinal + 1), ordinal: ordinal, name: name)
                                }
                            }
                            self.cache(rows: progress.previewRows, at: 0)
                            if !progress.previewRows.isEmpty {
                                self.notifyRowsReloaded(offset: 0, count: progress.previewRows.count)
                            }
                        }
                    }
                )
                try Task.checkCancellation()
                guard generation == documentTaskGeneration else { return }
                warningCount = importResult.totalDiagnosticCount
                try await reloadMetadataAndFirstPage()
                guard generation == documentTaskGeneration else { return }
                phase = .ready
                updateStatus()
                if recoveryPolicy == .bestEffort, importResult.totalDiagnosticCount > 0 {
                    statusMessage = "Recovered with \(importResult.totalDiagnosticCount.formatted()) parsing warnings"
                    document?.updateChangeCount(.changeDone)
                    document?.recordRecovery()
                }
                documentTask = nil
            } catch is CancellationError {
                finishCancelledDocumentTask(generation: generation)
            } catch let diagnostic as CSVParseDiagnostic {
                guard generation == documentTaskGeneration else { return }
                documentTask = nil
                phase = .failed("Record \(diagnostic.location.record), field \(diagnostic.location.field): \(diagnostic.detail)")
                statusMessage = "Import stopped at byte \(diagnostic.location.byteOffset.formatted())"
            } catch {
                guard generation == documentTaskGeneration else { return }
                documentTask = nil
                fail(error)
            }
        }
    }

    func cancelBackgroundWork() {
        documentTaskGeneration &+= 1
        documentTask?.cancel()
        documentTask = nil
        for task in pendingPageTasks.values { task.cancel() }
        pendingPageTasks.removeAll()
        for task in trackedTasks.values { task.cancel() }
        trackedTasks.removeAll()
        activeOperationTaskID = nil
        activeOperation = nil
    }

    func prepareForClose() {
        cancelBackgroundWork()
        document = nil
    }

    func cancelImport() {
        guard case .importing = phase else { return }
        cancelBackgroundWork()
        phase = .cancelled
        statusMessage = "Import cancelled"
    }

    func cancelActiveOperation() {
        guard let id = activeOperationTaskID, let task = trackedTasks[id] else { return }
        task.cancel()
        statusMessage = "Cancelling operation…"
    }

    func retryImport() {
        guard let sourceURL else { return }
        open(sourceURL, dialect: dialect)
    }

    func openBestEffort() {
        guard let sourceURL else { return }
        open(sourceURL, dialect: dialect, recoveryPolicy: .bestEffort)
    }

    func applyFormat(_ proposedDialect: CSVDialect, delimiterText: String, quoteText: String) {
        guard delimiterText.count == 1, let delimiter = delimiterText.first, delimiter != "\n", delimiter != "\r",
              quoteText.count <= 1, quoteText.first != delimiter else {
            fail(CSVParseDiagnostic(
                reason: .invalidDialect,
                location: CSVSourceLocation(byteOffset: 0, record: 1, field: 1, line: 1),
                detail: "The delimiter must be one character and must differ from the optional quote character."
            ))
            return
        }
        var proposedDialect = proposedDialect
        proposedDialect.delimiter = delimiter
        proposedDialect.quote = quoteText.first
        if proposedDialect.quote == nil { proposedDialect.quotePolicy = .minimal }
        if !proposedDialect.encoding.isUnicode { proposedDialect.includesByteOrderMark = false }
        dialect = proposedDialect
        if phase.requiresReimport, let sourceURL {
            open(sourceURL, dialect: proposedDialect)
            return
        }
        if let sourceURL, document?.isDocumentEdited == false {
            open(sourceURL, dialect: proposedDialect)
            return
        }
        runTrackedTask { [self] in
            do {
                try await workspace.updateDialect(proposedDialect)
                statusMessage = "Output format updated"
                document?.updateChangeCount(.changeDone)
                document?.recordRecovery()
            } catch { fail(error) }
        }
    }

    var formatActionTitle: String {
        if phase.requiresReimport { return "Retry with Format" }
        if sourceURL != nil, document?.isDocumentEdited == false { return "Reopen with Format" }
        return "Apply to Save"
    }

    func didSave(to url: URL) {
        sourceURL = url
    }

    func row(at index: Int64) -> WorkspaceRow? {
        if let row = cachedRows[index] {
            touchCachedPage((index / pageSize) * pageSize)
            return row
        }
        requestPage(containing: index)
        return nil
    }

    func requestPage(containing index: Int64) {
        guard index >= 0, index < totalRowCount else { return }
        let offset = (index / pageSize) * pageSize
        guard pendingPageTasks[offset] == nil else { return }

        // Momentum scrolling can briefly ask for many distant pages. Cancel stale requests
        // before they reach the workspace actor instead of filling a queue the user no longer sees.
        for (pendingOffset, task) in pendingPageTasks where abs(pendingOffset - offset) > pageSize {
            task.cancel()
        }
        pendingPageTasks[offset] = Task { [weak self] in
            guard let self else { return }
            defer { self.pendingPageTasks.removeValue(forKey: offset) }
            guard !Task.isCancelled else { return }
            do {
                let page = try await workspace.page(offset: offset, limit: Int(pageSize))
                guard !Task.isCancelled else { return }
                cache(rows: page.rows, at: offset)
                totalRowCount = page.totalRowCount
                notifyRowsReloaded(offset: offset, count: page.rows.count)
            } catch {
                guard !Task.isCancelled else { return }
                fail(error)
            }
        }
    }

    func edit(rowID: Int64, columnOrdinal: Int, value: String, registerUndo: Bool = true) {
        guard phase.isInteractive else { return }
        let columnID = columnOrdinal < columns.count ? columns[columnOrdinal].id : nil
        let affectsActiveView = columnID.map { id in
            activeFilters.contains(where: { $0.columnID == id })
                || activeSorts.contains(where: { $0.columnID == id })
        } ?? false
        runTrackedTask { [self] in
            do {
                let previous = try await workspace.updateCell(rowID: rowID, columnOrdinal: columnOrdinal, value: value)
                if let index = rowIndexByID[rowID], var row = cachedRows[index] {
                    while row.values.count <= columnOrdinal { row.values.append("") }
                    row.values[columnOrdinal] = value
                    cachedRows[index] = row
                }
                if registerUndo, let undo = document?.undoManager {
                    undo.registerUndo(withTarget: self) { target in
                        Task { @MainActor in
                            target.edit(rowID: rowID, columnOrdinal: columnOrdinal, value: previous)
                        }
                    }
                    undo.setActionName("Edit Cell")
                }
                document?.updateChangeCount(.changeDone)
                document?.recordRecovery()
                if await workspace.hasActiveView(), affectsActiveView {
                    try await reloadVisibleData()
                } else if let index = rowIndexByID[rowID] {
                    notifyRowsReloaded(offset: index, count: 1)
                } else {
                    NotificationCenter.default.post(name: .tableToolGridReload, object: self)
                }
            } catch { fail(error) }
        }
    }

    func renameColumn(_ column: WorkspaceColumn, to name: String) {
        guard !name.isEmpty else { return }
        let previous = column.name
        runTrackedTask { [self] in
            do {
                try await workspace.renameColumn(id: column.id, name: name)
                if let index = columns.firstIndex(where: { $0.id == column.id }) { columns[index].name = name }
                document?.undoManager?.registerUndo(withTarget: self) { target in
                    Task { @MainActor in
                        if let current = target.columns.first(where: { $0.id == column.id }) {
                            target.renameColumn(current, to: previous)
                        }
                    }
                }
                document?.undoManager?.setActionName("Rename Column")
                document?.updateChangeCount(.changeDone)
                document?.recordRecovery()
            } catch { fail(error) }
        }
    }

    func reorderColumns(ids: [Int64], registerUndo: Bool = true) {
        let previous = columns.map(\.id)
        guard ids.count == previous.count, ids != previous else { return }
        runTrackedTask(title: "Reordering columns…") { [self] in
            do {
                try await workspace.reorderColumns(ids: ids)
                columns = try await workspace.columns()
                try await reloadVisibleData()
                if registerUndo, let undo = document?.undoManager {
                    undo.registerUndo(withTarget: self) { target in
                        Task { @MainActor in
                            target.reorderColumns(ids: previous)
                        }
                    }
                    undo.setActionName("Reorder Columns")
                }
                document?.updateChangeCount(.changeDone)
                document?.recordRecovery()
            } catch { fail(error) }
        }
    }

    func addColumn(relativeToSelectionAfter after: Bool? = nil) {
        guard phase.isInteractive else { return }
        let ordinal: Int
        if let after, let selected = selectedColumnOrdinals.first {
            ordinal = selected + (after ? 1 : 0)
        } else {
            ordinal = columns.count
        }
        runTrackedTask(title: "Adding column…") { [self] in
            do {
                let inserted = try await workspace.insertColumn(at: ordinal)
                columns = try await workspace.columns()
                if let undo = document?.undoManager {
                    undo.registerUndo(withTarget: self) { target in
                        Task { @MainActor in target.deleteColumn(id: inserted.id, actionName: "Insert Column") }
                    }
                    undo.setActionName("Insert Column")
                }
                document?.updateChangeCount(.changeDone)
                document?.recordRecovery()
            } catch { fail(error) }
        }
    }

    func duplicateSelectedColumn() {
        guard let ordinal = selectedColumnOrdinals.first, ordinal < columns.count else { NSSound.beep(); return }
        runTrackedTask(title: "Duplicating column…") { [self] in
            do {
                let duplicate = try await workspace.duplicateColumn(id: columns[ordinal].id)
                columns = try await workspace.columns()
                try await reloadVisibleData()
                if let undo = document?.undoManager {
                    undo.registerUndo(withTarget: self) { target in
                        Task { @MainActor in target.deleteColumn(id: duplicate.id, actionName: "Duplicate Column") }
                    }
                    undo.setActionName("Duplicate Column")
                }
                document?.updateChangeCount(.changeDone)
                document?.recordRecovery()
            } catch { fail(error) }
        }
    }

    func deleteSelectedColumn() {
        let ids = selectedColumnOrdinals.compactMap { $0 < columns.count ? columns[$0].id : nil }
        guard !ids.isEmpty else { NSSound.beep(); return }
        if ids.count == 1 {
            deleteColumn(id: ids[0], actionName: "Delete Column")
        } else {
            deleteColumns(ids: ids, actionName: "Delete Columns")
        }
    }

    private func deleteColumn(id: Int64, actionName: String) {
        runTrackedTask(title: "Deleting column…") { [self] in
            do {
                let removed = try await workspace.deleteColumn(id: id)
                selectedColumnOrdinals.removeAll()
                columns = try await workspace.columns()
                try await reloadVisibleData()
                if let undo = document?.undoManager {
                    undo.registerUndo(withTarget: self) { target in
                        Task { @MainActor in target.restoreColumn(removed, actionName: actionName) }
                    }
                    undo.setActionName(actionName)
                }
                document?.updateChangeCount(.changeDone)
                document?.recordRecovery()
            } catch { fail(error) }
        }
    }

    private func restoreColumn(_ column: WorkspaceColumnSnapshot, actionName: String) {
        runTrackedTask(title: "Restoring column…") { [self] in
            do {
                _ = try await workspace.restoreColumn(column)
                columns = try await workspace.columns()
                try await reloadVisibleData()
                if let undo = document?.undoManager {
                    undo.registerUndo(withTarget: self) { target in
                        Task { @MainActor in target.deleteColumn(id: column.id, actionName: actionName) }
                    }
                    undo.setActionName(actionName)
                }
                document?.updateChangeCount(.changeDone)
                document?.recordRecovery()
            } catch { fail(error) }
        }
    }

    private func deleteColumns(ids: [Int64], actionName: String) {
        runTrackedTask(title: "Deleting columns…") { [self] in
            do {
                let removed = try await workspace.deleteColumns(ids: ids)
                selectedColumnOrdinals.removeAll()
                columns = try await workspace.columns()
                try await reloadVisibleData()
                if let undo = document?.undoManager {
                    undo.registerUndo(withTarget: self) { target in
                        Task { @MainActor in target.restoreColumns(removed, actionName: actionName) }
                    }
                    undo.setActionName(actionName)
                }
                document?.updateChangeCount(.changeDone)
                document?.recordRecovery()
            } catch { fail(error) }
        }
    }

    private func restoreColumns(_ snapshots: [WorkspaceColumnSnapshot], actionName: String) {
        runTrackedTask(title: "Restoring columns…") { [self] in
            do {
                for snapshot in snapshots.sorted(by: { $0.ordinal < $1.ordinal }) {
                    _ = try await workspace.restoreColumn(snapshot)
                }
                columns = try await workspace.columns()
                try await reloadVisibleData()
                if let undo = document?.undoManager {
                    let ids = snapshots.map(\.id)
                    undo.registerUndo(withTarget: self) { target in
                        Task { @MainActor in target.deleteColumns(ids: ids, actionName: actionName) }
                    }
                    undo.setActionName(actionName)
                }
                document?.updateChangeCount(.changeDone)
                document?.recordRecovery()
            } catch { fail(error) }
        }
    }

    func addRow(after: Bool = true) {
        guard phase.isInteractive else { return }
        let selectedID = selectedRowIDs.min { first, second in
            let firstIndex = rowIndexByID[first] ?? (after ? .min : .max)
            let secondIndex = rowIndexByID[second] ?? (after ? .min : .max)
            return after ? firstIndex > secondIndex : firstIndex < secondIndex
        }
        runTrackedTask(title: "Adding row…") { [self] in
            do {
                let inserted = try await workspace.insertRows(
                    [Array(repeating: "", count: columns.count)],
                    relativeTo: selectedID,
                    after: after
                )
                try await reloadVisibleData()
                if let undo = document?.undoManager {
                    let ids = inserted.map(\.id)
                    undo.registerUndo(withTarget: self) { target in
                        Task { @MainActor in target.deleteRows(ids: ids, actionName: "Insert Row") }
                    }
                    undo.setActionName("Insert Row")
                }
                document?.updateChangeCount(.changeDone)
                document?.recordRecovery()
            } catch { fail(error) }
        }
    }

    func deleteSelectedRows() {
        guard phase.isInteractive, !selectedRowIndexes.isEmpty else { NSSound.beep(); return }
        let ranges = visibleRanges(from: selectedRowIndexes)
        let actionName = selectedRowIndexes.count == 1 ? "Delete Row" : "Delete Rows"
        runTrackedTask(title: "Deleting rows…") { [self] in
            do {
                let removed = try await workspace.deleteRowsToSnapshot(inVisibleRanges: ranges)
                selectedRowIDs.removeAll()
                selectedRowIndexes.removeAll()
                try await reloadVisibleData()
                registerRowRestoreUndo(removed, actionName: actionName)
                document?.updateChangeCount(.changeDone)
                document?.recordRecovery()
            } catch { fail(error) }
        }
    }

    private func deleteRows(ids: [Int64], actionName: String) {
        runTrackedTask(title: "Deleting rows…") { [self] in
            do {
                let removed = try await workspace.deleteRowsToSnapshot(ids: ids)
                selectedRowIDs.removeAll()
                selectedRowIndexes.removeAll()
                try await reloadVisibleData()
                registerRowRestoreUndo(removed, actionName: actionName)
                document?.updateChangeCount(.changeDone)
                document?.recordRecovery()
            } catch { fail(error) }
        }
    }

    private func registerRowRestoreUndo(_ rows: WorkspaceRowBatchSnapshot, actionName: String) {
        guard rows.count > 0, let undo = document?.undoManager else { return }
        undo.registerUndo(withTarget: self) { target in
            Task { @MainActor in target.restoreRows(rows, actionName: actionName) }
        }
        undo.setActionName(actionName)
    }

    func copyRows(_ rowIndexes: IndexSet, columns columnIndexes: IndexSet) {
        let rows = rowIndexes.isEmpty ? IndexSet(integersIn: 0..<Int(clamping: totalRowCount)) : rowIndexes
        let selectedColumns = columnIndexes.isEmpty ? IndexSet(integersIn: 0..<columns.count) : columnIndexes
        let ranges = visibleRanges(from: rows)
        runTrackedTask(title: "Copying rows…") { [self] in
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("TableToolX-Copy-\(UUID().uuidString).tsv")
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                var clipboardDialect = CSVDialect.tsv
                clipboardDialect.hasHeader = false
                clipboardDialect.hasFinalNewline = false
                let count = try await workspace.exportSelection(
                    to: temporary,
                    visibleRanges: ranges,
                    columnOrdinals: Array(selectedColumns),
                    dialect: clipboardDialect
                )
                let readTask = Task.detached(priority: .userInitiated) {
                    let handle = try FileHandle(forReadingFrom: temporary)
                    defer { try? handle.close() }
                    var data = Data()
                    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                        try Task.checkCancellation()
                        data.append(chunk)
                    }
                    try Task.checkCancellation()
                    guard let text = String(data: data, encoding: .utf8) else {
                        throw CocoaError(.fileReadInapplicableStringEncoding)
                    }
                    return text
                }
                let text = try await withTaskCancellationHandler(
                    operation: { try await readTask.value },
                    onCancel: { readTask.cancel() }
                )
                try Task.checkCancellation()
                NSPasteboard.general.declareTypes([.tabularText, .string], owner: nil)
                NSPasteboard.general.setString(text, forType: .tabularText)
                NSPasteboard.general.setString(text, forType: .string)
                statusMessage = "Copied \(count.formatted()) rows"
            } catch { fail(error) }
        }
    }

    private func restoreRows(_ rows: WorkspaceRowBatchSnapshot, actionName: String) {
        runTrackedTask(title: "Restoring rows…") { [self] in
            do {
                try await workspace.restoreRows(from: rows)
                try await reloadVisibleData()
                if let undo = document?.undoManager {
                    undo.registerUndo(withTarget: self) { target in
                        Task { @MainActor in target.removeRows(in: rows, actionName: actionName) }
                    }
                    undo.setActionName(actionName)
                }
                document?.updateChangeCount(.changeDone)
                document?.recordRecovery()
            } catch { fail(error) }
        }
    }

    private func removeRows(in rows: WorkspaceRowBatchSnapshot, actionName: String) {
        runTrackedTask(title: "Deleting rows…") { [self] in
            do {
                try await workspace.removeRows(in: rows)
                selectedRowIDs.removeAll()
                selectedRowIndexes.removeAll()
                try await reloadVisibleData()
                registerRowRestoreUndo(rows, actionName: actionName)
                document?.updateChangeCount(.changeDone)
                document?.recordRecovery()
            } catch { fail(error) }
        }
    }

    func paste(_ text: String, afterVisibleRow rowIndex: Int64?) {
        guard phase.isInteractive else { return }
        let data = Data(text.utf8)
        var pasteDialect = (try? CSVDialectDetector.detect(sample: data).dialect)
            ?? CSVDialect(delimiter: text.contains("\t") ? "\t" : dialect.delimiter, hasHeader: false)
        pasteDialect.encoding = .utf8
        pasteDialect.includesByteOrderMark = false
        pasteDialect.hasHeader = false
        pasteDialect.hasFinalNewline = text.hasSuffix("\n") || text.hasSuffix("\r")
        let records: [CSVRecord]
        do {
            records = try CSVStreamParser(dialect: pasteDialect, recoveryPolicy: .strict).parse(data: data)
        } catch {
            fail(error)
            return
        }
        guard !records.isEmpty else { return }
        runTrackedTask(title: "Pasting rows…") { [self] in
            do {
                let target: WorkspaceRow?
                if let rowIndex {
                    target = try await workspace.rows(inVisibleRanges: [rowIndex..<(rowIndex + 1)]).first
                } else {
                    target = nil
                }
                let paste = try await workspace.insertPastedRows(
                    records.map(\.values),
                    startingColumn: 0,
                    relativeTo: target?.id
                )
                columns = try await workspace.columns()
                try await reloadVisibleData()
                registerPasteUndo(paste, removing: true)
                document?.updateChangeCount(.changeDone)
                document?.recordRecovery()
            } catch { fail(error) }
        }
    }

    private func registerPasteUndo(_ paste: WorkspacePasteSnapshot, removing: Bool) {
        guard let undo = document?.undoManager else { return }
        undo.registerUndo(withTarget: self) { target in
            Task { @MainActor in target.applyPasteUndo(paste, removing: removing) }
        }
        undo.setActionName("Paste Data")
    }

    private func applyPasteUndo(_ paste: WorkspacePasteSnapshot, removing: Bool) {
        runTrackedTask(title: removing ? "Undoing paste…" : "Redoing paste…") { [self] in
            do {
                if removing { try await workspace.removePaste(paste) }
                else { try await workspace.restorePaste(paste) }
                columns = try await workspace.columns()
                try await reloadVisibleData()
                registerPasteUndo(paste, removing: !removing)
                document?.updateChangeCount(.changeDone)
                document?.recordRecovery()
            } catch { fail(error) }
        }
    }

    func moveRows(ids: [Int64], beforeVisibleRow row: Int64) {
        guard phase.isInteractive else { return }
        runTrackedTask(title: "Reordering rows…") { [self] in
            do {
                let target = row < totalRowCount
                    ? try await workspace.rows(inVisibleRanges: [row..<(row + 1)]).first?.id
                    : nil
                let previous = try await workspace.moveRows(ids: ids, beforeRowID: target)
                try await reloadVisibleData()
                registerRowOrderUndo(previous)
                document?.updateChangeCount(.changeDone)
                document?.recordRecovery()
            } catch { fail(error) }
        }
    }

    private func restoreRowOrder(_ order: [Int64]) {
        runTrackedTask(title: "Restoring row order…") { [self] in
            do {
                let previous = try await workspace.reorderRows(idsInDocumentOrder: order)
                try await reloadVisibleData()
                registerRowOrderUndo(previous)
                document?.updateChangeCount(.changeDone)
                document?.recordRecovery()
            } catch { fail(error) }
        }
    }

    private func registerRowOrderUndo(_ order: [Int64]) {
        guard let undo = document?.undoManager else { return }
        undo.registerUndo(withTarget: self) { target in
            Task { @MainActor in target.restoreRowOrder(order) }
        }
        undo.setActionName("Move Rows")
    }

    func runFind() {
        guard phase.isInteractive else { return }
        guard !findText.isEmpty else { searchMatches = []; return }
        let query = findText
        let options = SearchOptions(caseSensitive: findIsCaseSensitive, regularExpression: findUsesRegex, columnOrdinals: selectedColumnOrdinals.isEmpty ? nil : Set(selectedColumnOrdinals))
        runTrackedTask(title: "Searching…") { [self] in
            do {
                searchMatches = try await workspace.search(query, options: options)
                activeMatchIndex = 0
                statusMessage = "\(searchMatches.count.formatted()) matches"
                revealActiveMatch()
            } catch { fail(error) }
        }
    }

    func nextMatch(backwards: Bool = false) {
        guard !searchMatches.isEmpty else { runFind(); return }
        activeMatchIndex = (activeMatchIndex + (backwards ? -1 : 1) + searchMatches.count) % searchMatches.count
        revealActiveMatch()
    }

    func replaceAll() {
        guard !findText.isEmpty else { return }
        let query = findText
        let replacement = replaceText
        let options = SearchOptions(caseSensitive: findIsCaseSensitive, regularExpression: findUsesRegex, columnOrdinals: selectedColumnOrdinals.isEmpty ? nil : Set(selectedColumnOrdinals))
        runTrackedTask(title: "Replacing matches…") { [self] in
            do {
                let result = try await workspace.replaceAll(query, replacement: replacement, options: options)
                try await reloadVisibleData()
                statusMessage = "Replaced \(result.replacementCount.formatted()) occurrences"
                if let snapshotID = result.snapshotID {
                    registerReplacementUndo(snapshotID)
                    document?.updateChangeCount(.changeDone)
                    document?.recordRecovery()
                }
                searchMatches = try await workspace.search(query, options: options)
                activeMatchIndex = 0
                if !searchMatches.isEmpty { revealActiveMatch() }
            } catch { fail(error) }
        }
    }

    private func registerReplacementUndo(_ snapshotID: String) {
        guard let undo = document?.undoManager else { return }
        undo.registerUndo(withTarget: self) { target in
            Task { @MainActor in target.applyReplacementUndo(snapshotID) }
        }
        undo.setActionName("Replace All")
    }

    private func applyReplacementUndo(_ snapshotID: String) {
        runTrackedTask(title: "Restoring replacements…") { [self] in
            do {
                let inverseSnapshotID = try await workspace.restoreReplacement(snapshotID: snapshotID)
                try await reloadVisibleData()
                registerReplacementUndo(inverseSnapshotID)
                document?.updateChangeCount(.changeDone)
                document?.recordRecovery()
            } catch { fail(error) }
        }
    }

    func applyFilter() {
        guard phase.isInteractive else { return }
        guard let columnID = filterColumnID ?? columns.first?.id else { return }
        let previousFilters = activeFilters
        let proposedFilters = filterValue.isEmpty && filterOperation != .isEmpty && filterOperation != .isNotEmpty
            ? []
            : [FilterRule(columnID: columnID, comparison: filterComparison, operation: filterOperation, value: filterValue)]
        let definition = ViewDefinition(filters: proposedFilters, sorts: activeSorts)
        runTrackedTask(title: "Filtering rows…") { [self] in
            activeFilters = proposedFilters
            do {
                try await workspace.applyView(definition)
                try await reloadVisibleData()
                statusMessage = activeFilters.isEmpty ? "Filter cleared" : "Filtered to \(totalRowCount.formatted()) rows"
            } catch {
                activeFilters = previousFilters
                fail(error)
            }
        }
    }

    func sortSelectedColumn(ascending: Bool) {
        guard phase.isInteractive else { return }
        guard let ordinal = selectedColumnOrdinals.first, ordinal < columns.count else { NSSound.beep(); return }
        sortColumn(at: ordinal, ascending: ascending)
    }

    func toggleSortColumn(at ordinal: Int) {
        guard phase.isInteractive, ordinal >= 0, ordinal < columns.count else { return }
        let columnID = columns[ordinal].id
        let ascending = activeSortColumnID == columnID ? !activeSortAscending : true
        sortColumn(at: ordinal, ascending: ascending)
    }

    private func sortColumn(at ordinal: Int, ascending: Bool) {
        let id = columns[ordinal].id
        let previousSorts = activeSorts
        let previousSortColumnID = activeSortColumnID
        let previousSortAscending = activeSortAscending
        let proposedSorts = [SortRule(columnID: id, comparison: sortComparison, ascending: ascending)]
        let definition = ViewDefinition(filters: activeFilters, sorts: proposedSorts)
        let columnName = columns[ordinal].name
        runTrackedTask(title: "Sorting rows…") { [self] in
            activeSorts = proposedSorts
            activeSortColumnID = id
            activeSortAscending = ascending
            do {
                try await workspace.applyView(definition)
                try await reloadVisibleData()
                let direction = ascending ? "ascending" : "descending"
                statusMessage = "Sorted \(columnName) \(direction) as \(sortComparison.displayName.lowercased())"
            } catch {
                activeSorts = previousSorts
                activeSortColumnID = previousSortColumnID
                activeSortAscending = previousSortAscending
                fail(error)
            }
        }
    }

    func clearView() {
        guard phase.isInteractive else { return }
        let previousFilters = activeFilters
        let previousSorts = activeSorts
        runTrackedTask(title: "Clearing sort and filter…") { [self] in
            activeFilters = []
            activeSorts = []
            activeSortColumnID = nil
            activeSortAscending = true
            do { try await workspace.applyView(.documentOrder); try await reloadVisibleData(); updateStatus() }
            catch {
                activeFilters = previousFilters
                activeSorts = previousSorts
                synchronizeSortPresentation()
                fail(error)
            }
        }
    }

    private func revealActiveMatch() {
        guard activeMatchIndex < searchMatches.count else { return }
        let match = searchMatches[activeMatchIndex]
        runTrackedTask { [self] in
            do {
                guard let index = try await workspace.visibleIndex(ofRowID: match.rowID) else {
                    statusMessage = "The matching row is no longer visible"
                    return
                }
                NotificationCenter.default.post(name: .tableToolRevealCell, object: self, userInfo: ["row": index, "column": match.columnOrdinal])
            } catch { fail(error) }
        }
    }

    private func reloadMetadataAndFirstPage() async throws {
        columns = try await workspace.columns()
        let definition = await workspace.currentViewDefinition()
        activeFilters = definition.filters
        activeSorts = definition.sorts
        synchronizeSortPresentation()
        try await reloadVisibleData()
        filterColumnID = columns.first?.id
    }

    private func synchronizeSortPresentation() {
        activeSortColumnID = activeSorts.first?.columnID
        activeSortAscending = activeSorts.first?.ascending ?? true
        if let comparison = activeSorts.first?.comparison {
            sortComparison = comparison
        }
    }

    @discardableResult
    private func beginDocumentTask() -> Int {
        cancelBackgroundWork()
        return documentTaskGeneration
    }

    private func finishCancelledDocumentTask(generation: Int) {
        guard generation == documentTaskGeneration else { return }
        documentTask = nil
        phase = .idle
        statusMessage = "Cancelled"
    }

    private func reloadVisibleData() async throws {
        for task in pendingPageTasks.values { task.cancel() }
        pendingPageTasks.removeAll()
        cachedRows.removeAll()
        rowIndexByID.removeAll()
        cachedPageOffsets.removeAll()
        totalRowCount = try await workspace.rowCount()
        let first = try await workspace.page(offset: 0, limit: Int(pageSize))
        cache(rows: first.rows, at: 0)
        NotificationCenter.default.post(name: .tableToolGridReload, object: self)
    }

    private func cache(rows: [WorkspaceRow], at offset: Int64) {
        for (position, row) in rows.enumerated() {
            let visibleIndex = offset + Int64(position)
            cachedRows[visibleIndex] = row
            rowIndexByID[row.id] = visibleIndex
        }
        touchCachedPage(offset)
        while cachedPageOffsets.count > maximumCachedPageCount {
            evictPage(at: cachedPageOffsets.removeFirst())
        }
    }

    private func touchCachedPage(_ offset: Int64) {
        guard cachedPageOffsets.last != offset else { return }
        if let existing = cachedPageOffsets.firstIndex(of: offset) {
            cachedPageOffsets.remove(at: existing)
        }
        cachedPageOffsets.append(offset)
    }

    private func evictPage(at offset: Int64) {
        for index in cachedRows.keys.filter({ $0 >= offset && $0 < offset + pageSize }) {
            if let row = cachedRows.removeValue(forKey: index), rowIndexByID[row.id] == index {
                rowIndexByID.removeValue(forKey: row.id)
            }
        }
    }

    private func updateStatus() {
        statusMessage = "\(totalRowCount.formatted()) rows × \(columns.count.formatted()) columns"
    }

    private func notifyRowsReloaded(offset: Int64, count: Int) {
        NotificationCenter.default.post(
            name: .tableToolRowsReload,
            object: self,
            userInfo: ["offset": offset, "count": count]
        )
    }

    private func previewColumnName(_ index: Int) -> String {
        var number = index + 1
        var result = ""
        while number > 0 {
            number -= 1
            result.insert(Character(UnicodeScalar(65 + number % 26)!), at: result.startIndex)
            number /= 26
        }
        return result
    }

    private func visibleRanges(from indexes: IndexSet) -> [Range<Int64>] {
        indexes.rangeView.map { Int64($0.lowerBound)..<Int64($0.upperBound) }
    }

    private func fail(_ error: Error) {
        guard !(error is CancellationError) else { return }
        statusMessage = error.localizedDescription
        if !phase.isInteractive { phase = .failed(error.localizedDescription) }
        document?.presentError(error)
    }

    private func runTrackedTask(
        title: String? = nil,
        _ operation: @escaping @MainActor () async -> Void
    ) {
        if title != nil, activeOperationTaskID != nil {
            NSSound.beep()
            return
        }
        let id = UUID()
        if let title {
            activeOperationTaskID = id
            activeOperation = title
        }
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                trackedTasks.removeValue(forKey: id)
                if activeOperationTaskID == id {
                    activeOperationTaskID = nil
                    activeOperation = nil
                    if Task.isCancelled { updateStatus() }
                }
            }
            guard !Task.isCancelled else { return }
            await operation()
        }
        trackedTasks[id] = task
    }
}

extension Notification.Name {
    static let tableToolRevealCell = Notification.Name("TableToolX.revealCell")
    static let tableToolRowsReload = Notification.Name("TableToolX.rowsReload")
    static let tableToolGridReload = Notification.Name("TableToolX.gridReload")
}
