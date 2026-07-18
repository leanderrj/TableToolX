import AppKit
import SwiftUI

@MainActor
final class TableWindowController: NSWindowController {
    init(viewModel: DocumentViewModel) {
        let root = TableDocumentView(viewModel: viewModel)
        let hosting = NSHostingController(rootView: root)
        let window = FileDropWindow(contentViewController: hosting)
        window.openDroppedFiles = { urls in
            let documentToReplace = viewModel.document?.canBeReplacedByDroppedFile == true
                ? viewModel.document
                : nil
            for url in urls {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
                    if let error {
                        NSApp.presentError(error)
                    } else if document != nil, documentToReplace?.windowControllers.isEmpty == false {
                        documentToReplace?.close()
                    }
                }
            }
        }
        window.setContentSize(NSSize(width: 1_100, height: 720))
        window.minSize = NSSize(width: 700, height: 420)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .unifiedTitleAndToolbar]
        window.titlebarAppearsTransparent = false
        window.tabbingMode = .preferred
        super.init(window: window)
        shouldCascadeWindows = true
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
private final class FileDropWindow: NSWindow, NSDraggingDestination {
    var openDroppedFiles: (([URL]) -> Void)?

    init(contentViewController: NSViewController) {
        super.init(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.contentViewController = contentViewController
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("FileDropWindow does not support coder initialization")
    }

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedFileURLs(from: sender).isEmpty ? [] : .copy
    }

    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedFileURLs(from: sender).isEmpty ? [] : .copy
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = droppedFileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        openDroppedFiles?(urls)
        return true
    }

    private func droppedFileURLs(from draggingInfo: any NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] ?? []
        return objects.map { $0 as URL }.filter { url in
            var isDirectory: ObjCBool = false
            return url.isFileURL
                && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
    }
}
