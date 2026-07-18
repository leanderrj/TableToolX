import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    #if canImport(Sparkle)
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    #endif
    private var recentDocumentsMenu: NSMenu?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if canImport(Sparkle)
        // Instantiating the standard controller starts scheduled checks. Keeping the
        // property lazy avoids linking it into core-only tools, but it must be touched at
        // launch rather than only when the user invokes Check for Updates manually.
        _ = updaterController
        #endif
        NSApp.activate(ignoringOtherApps: true)
        if !restoreRecoverableDocuments() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if NSDocumentController.shared.documents.isEmpty {
                    NSDocumentController.shared.newDocument(nil)
                }
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func restoreRecoverableDocuments() -> Bool {
        let records = RecoveryManager.records()
        guard !records.isEmpty else { return false }
        let alert = NSAlert()
        alert.messageText = records.count == 1 ? "Restore an unsaved document?" : "Restore \(records.count) unsaved documents?"
        alert.informativeText = "Table Tool X found editing workspaces from an earlier session. They remain only on this Mac."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Discard")
        if alert.runModal() == .alertSecondButtonReturn {
            RecoveryManager.clearAll()
            return false
        }
        for record in records {
            do {
                let document = try TableDocument(recovering: record)
                NSDocumentController.shared.addDocument(document)
                document.makeWindowControllers()
                document.showWindows()
            } catch {
                RecoveryManager.remove(id: record.id, workspaceURL: record.workspaceURL, deleteWorkspace: true)
            }
        }
        return true
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Table Tool X",
            .credits: NSAttributedString(string: "A modern Swift continuation of Jakob Egger's MIT-licensed Table Tool."),
            .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        ])
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        #if canImport(Sparkle)
        updaterController.checkForUpdates(sender)
        #else
        NSWorkspace.shared.open(URL(string: "https://github.com/leanderrj/TableToolX/releases/latest")!)
        #endif
    }

    private func makeMainMenu() -> NSMenu {
        let menu = NSMenu()

        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu(title: "Table Tool X")
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Table Tool X", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Table Tool X", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Table Tool X", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = menuItem(title: "File", entries: [
            ("New", #selector(NSDocumentController.newDocument(_:)), "n", [.command]),
            ("Open…", #selector(NSDocumentController.openDocument(_:)), "o", [.command]),
            ("-", nil, "", []),
            ("Close", #selector(NSWindow.performClose(_:)), "w", [.command]),
            ("Save", #selector(NSDocument.save(_:)), "s", [.command]),
            ("Save As…", #selector(NSDocument.saveAs(_:)), "S", [.command, .shift]),
            ("Revert to Saved", #selector(NSDocument.revertToSaved(_:)), "", []),
            ("-", nil, "", []),
            ("Convert / Export…", #selector(TableDocument.exportDocument(_:)), "e", [.command, .shift]),
            ("Export Visible Rows…", #selector(TableDocument.exportVisible(_:)), "e", [.command, .option, .shift])
        ])
        let recentRoot = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = self
        recentRoot.submenu = recentMenu
        fileItem.submenu?.insertItem(recentRoot, at: 2)
        recentDocumentsMenu = recentMenu
        menu.addItem(fileItem)
        menu.addItem(menuItem(title: "Edit", entries: [
            ("Undo", Selector(("undo:")), "z", [.command]),
            ("Redo", Selector(("redo:")), "Z", [.command, .shift]),
            ("-", nil, "", []),
            ("Cut", #selector(NSText.cut(_:)), "x", [.command]),
            ("Copy", #selector(NSText.copy(_:)), "c", [.command]),
            ("Paste", #selector(NSText.paste(_:)), "v", [.command]),
            ("Delete", #selector(NSText.delete(_:)), "", []),
            ("Select All", #selector(NSText.selectAll(_:)), "a", [.command]),
            ("-", nil, "", []),
            ("Find…", #selector(TableDocument.showFind(_:)), "f", [.command]),
            ("Find Next", #selector(TableDocument.findNext(_:)), "g", [.command]),
            ("Find Previous", #selector(TableDocument.findPrevious(_:)), "g", [.command, .shift]),
            ("-", nil, "", []),
            ("Insert Row Above", #selector(TableDocument.addRowAbove(_:)), "", []),
            ("Insert Row Below", #selector(TableDocument.addRowBelow(_:)), "", []),
            ("Delete Selected Rows", #selector(TableDocument.deleteSelectedRows(_:)), "", []),
            ("-", nil, "", []),
            ("Insert Column Left", #selector(TableDocument.addColumnLeft(_:)), "", []),
            ("Insert Column Right", #selector(TableDocument.addColumnRight(_:)), "", []),
            ("Delete Selected Columns", #selector(TableDocument.deleteSelectedColumns(_:)), "", [])
        ]))

        menu.addItem(menuItem(title: "Window", entries: [
            ("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", [.command]),
            ("Zoom", #selector(NSWindow.performZoom(_:)), "", []),
            ("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "", [])
        ]))
        NSApp.windowsMenu = menu.item(withTitle: "Window")?.submenu

        menu.addItem(menuItem(title: "Help", entries: [
            ("Table Tool X on GitHub", #selector(openProjectHomepage), "", [])
        ]))
        return menu
    }

    @objc private func openProjectHomepage() {
        NSWorkspace.shared.open(URL(string: "https://github.com/leanderrj/TableToolX")!)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentDocumentsMenu else { return }
        menu.removeAllItems()
        let recentURLs = NSDocumentController.shared.recentDocumentURLs
        if recentURLs.isEmpty {
            let empty = NSMenuItem(title: "No Recent Documents", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for url in recentURLs {
                let item = NSMenuItem(
                    title: FileManager.default.displayName(atPath: url.path),
                    action: #selector(openRecentDocument(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = url
                item.toolTip = url.path
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let clear = menu.addItem(
            withTitle: "Clear Menu",
            action: #selector(NSDocumentController.clearRecentDocuments(_:)),
            keyEquivalent: ""
        )
        clear.target = NSDocumentController.shared
        clear.isEnabled = !recentURLs.isEmpty
    }

    @objc private func openRecentDocument(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }

    private typealias MenuEntry = (String, Selector?, String, NSEvent.ModifierFlags)

    private func menuItem(title: String, entries: [MenuEntry]) -> NSMenuItem {
        let root = NSMenuItem()
        let submenu = NSMenu(title: title)
        root.submenu = submenu
        submenu.title = title
        for entry in entries {
            if entry.0 == "-" {
                submenu.addItem(.separator())
            } else {
                let item = submenu.addItem(withTitle: entry.0, action: entry.1, keyEquivalent: entry.2.lowercased())
                item.keyEquivalentModifierMask = entry.3
            }
        }
        return root
    }
}
