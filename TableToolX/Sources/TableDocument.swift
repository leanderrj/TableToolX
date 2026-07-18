import AppKit
import SwiftUI
import TableToolCore
import UniformTypeIdentifiers

@MainActor
@objc(TableDocument)
final class TableDocument: NSDocument {
    let viewModel: DocumentViewModel
    private let recoveryID: UUID
    private let workspaceURL: URL
    private var isRecoveredDocument = false
    private var securityScopedRecoveryURL: URL?
    private var pendingRecoveryTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    nonisolated(unsafe) private var pendingSourceURL: URL?
    nonisolated(unsafe) private var hasLoadedWindow = false

    override init() {
        recoveryID = UUID()
        workspaceURL = try! DocumentWorkspace.temporaryURL(identifier: recoveryID)
        let workspace = try! DocumentWorkspace(databaseURL: workspaceURL)
        viewModel = DocumentViewModel(workspace: workspace)
        super.init()
        viewModel.document = self
    }

    init(recovering record: RecoveryRecord) throws {
        recoveryID = record.id
        workspaceURL = record.workspaceURL
        isRecoveredDocument = true
        let workspace = try DocumentWorkspace(databaseURL: record.workspaceURL)
        viewModel = DocumentViewModel(workspace: workspace)
        super.init()
        if let bookmark = record.sourceBookmark {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), resolved.startAccessingSecurityScopedResource() {
                securityScopedRecoveryURL = resolved
                fileURL = resolved
            } else {
                fileURL = record.sourceURL
            }
        } else {
            fileURL = record.sourceURL
        }
        viewModel.document = self
    }

    override class var autosavesInPlace: Bool { true }
    override class var preservesVersions: Bool { true }

    var canBeReplacedByDroppedFile: Bool {
        fileURL == nil && !isRecoveredDocument && !isDocumentEdited
    }

    override func read(from url: URL, ofType typeName: String) throws {
        pendingSourceURL = url
        guard hasLoadedWindow else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.windowControllers.isEmpty, self.viewModel.document != nil else { return }
            self.pendingSourceURL = nil
            self.viewModel.open(url)
        }
    }

    override func makeWindowControllers() {
        let controller = TableWindowController(viewModel: viewModel)
        addWindowController(controller)
        if isRecoveredDocument {
            viewModel.restoreExisting(sourceURL: fileURL)
            updateChangeCount(.changeDone)
        } else if let source = pendingSourceURL {
            pendingSourceURL = nil
            viewModel.open(source)
        } else {
            viewModel.createNew()
        }
        hasLoadedWindow = true
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, completionHandler: @escaping (Error?) -> Void) {
        let workspace = viewModel.workspace
        Task {
            do {
                // DocumentWorkspace already commits exports atomically. Adding a second
                // temporary-file exchange here races AppKit's coordinated close/save and
                // can leave NSDocument looking for the writer's now-consumed staging URL.
                try await workspace.export(to: url)
                self.fileURL = url
                self.viewModel.didSave(to: url)
                self.updateChangeCount(.changeCleared)
                self.pendingRecoveryTask?.cancel()
                self.pendingRecoveryTask = nil
                RecoveryManager.remove(id: self.recoveryID, workspaceURL: self.workspaceURL, deleteWorkspace: false)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        savePanel.nameFieldStringValue = suggestedOutputName(suffix: nil)
        return true
    }

    @objc func addRow(_ sender: Any?) { viewModel.addRow() }
    @objc func addRowAbove(_ sender: Any?) { viewModel.addRow(after: false) }
    @objc func addRowBelow(_ sender: Any?) { viewModel.addRow(after: true) }
    @objc func deleteSelectedRows(_ sender: Any?) { viewModel.deleteSelectedRows() }
    @objc func addColumnLeft(_ sender: Any?) { viewModel.addColumn(relativeToSelectionAfter: false) }
    @objc func addColumnRight(_ sender: Any?) { viewModel.addColumn(relativeToSelectionAfter: true) }
    @objc func deleteSelectedColumns(_ sender: Any?) { viewModel.deleteSelectedColumn() }
    @objc func showFind(_ sender: Any?) { viewModel.isFindVisible = true }
    @objc func findNext(_ sender: Any?) { viewModel.nextMatch() }
    @objc func findPrevious(_ sender: Any?) { viewModel.nextMatch(backwards: true) }
    @objc func exportDocument(_ sender: Any?) { presentExportPanel(visibleRowsOnly: false) }

    func recordRecovery() {
        pendingRecoveryTask?.cancel()
        pendingRecoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, let self else { return }
            self.storeRecoveryRecord()
            self.pendingRecoveryTask = nil
        }
    }

    override func close() {
        viewModel.prepareForClose()
        exportTask?.cancel()
        exportTask = nil
        pendingRecoveryTask?.cancel()
        pendingRecoveryTask = nil
        // Reaching close means NSDocument has already completed its Save / Don't Save review.
        // Recovery is for abnormal termination only; retaining it here would resurrect edits
        // the user explicitly chose to discard.
        RecoveryManager.remove(id: recoveryID, workspaceURL: workspaceURL, deleteWorkspace: true)
        securityScopedRecoveryURL?.stopAccessingSecurityScopedResource()
        securityScopedRecoveryURL = nil
        super.close()
    }

    private func storeRecoveryRecord() {
        let sourceBookmark = try? fileURL?.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        RecoveryManager.store(RecoveryRecord(
            id: recoveryID,
            workspaceURL: workspaceURL,
            sourceURL: fileURL,
            sourceBookmark: sourceBookmark ?? nil,
            displayName: displayName,
            modifiedAt: Date()
        ))
    }

    @objc func exportVisible(_ sender: Any?) { presentExportPanel(visibleRowsOnly: true) }

    private func presentExportPanel(visibleRowsOnly: Bool) {
        guard let window = windowForSheet else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.nameFieldStringValue = suggestedOutputName(suffix: visibleRowsOnly ? "-filtered" : "-converted")
        let exportOptions = ExportOptionsModel(dialect: viewModel.dialect)
        let accessory = NSHostingView(rootView: ExportOptionsView(options: exportOptions))
        accessory.frame = NSRect(x: 0, y: 0, width: 390, height: 340)
        panel.accessoryView = accessory
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let dialect = try exportOptions.makeDialect()
                self.exportTask?.cancel()
                self.exportTask = Task { [weak self] in
                    guard let self else { return }
                    defer { self.exportTask = nil }
                    do {
                        try await self.viewModel.workspace.export(
                            to: url,
                            dialect: dialect,
                            visibleRowsOnly: visibleRowsOnly
                        )
                        try Task.checkCancellation()
                        self.viewModel.statusMessage = "Exported \(url.lastPathComponent)"
                    } catch is CancellationError {
                    } catch {
                        self.presentError(error)
                    }
                }
            } catch {
                self.presentError(error)
            }
        }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if viewModel.activeOperation != nil,
           item.action == Selector(("undo:")) || item.action == Selector(("redo:")) {
            return false
        }
        switch item.action {
        case #selector(addRow(_:)), #selector(addRowAbove(_:)), #selector(addRowBelow(_:)),
             #selector(addColumnLeft(_:)), #selector(addColumnRight(_:)), #selector(showFind(_:)):
            return viewModel.phase.isInteractive && viewModel.activeOperation == nil
        case #selector(findNext(_:)), #selector(findPrevious(_:)):
            return viewModel.phase.isInteractive
                && viewModel.activeOperation == nil
                && !viewModel.findText.isEmpty
        case #selector(deleteSelectedRows(_:)):
            return viewModel.phase.isInteractive
                && viewModel.activeOperation == nil
                && !viewModel.selectedRowIndexes.isEmpty
        case #selector(deleteSelectedColumns(_:)):
            return viewModel.phase.isInteractive
                && viewModel.activeOperation == nil
                && !viewModel.selectedColumnOrdinals.isEmpty
                && viewModel.selectedColumnOrdinals.count < viewModel.columns.count
        case #selector(exportDocument(_:)), #selector(exportVisible(_:)):
            return viewModel.phase.isInteractive
                && viewModel.activeOperation == nil
                && exportTask == nil
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    private func suggestedOutputName(suffix: String?) -> String {
        let base = (displayName as NSString).deletingPathExtension + (suffix ?? "")
        let extensionName = viewModel.dialect.delimiter == "\t" ? "tsv" : "csv"
        return base + "." + extensionName
    }
}
