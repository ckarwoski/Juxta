import AppKit

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(
        _ title: String, _ action: Selector?, _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func arrow(_ key: Int) -> String {
        String(Character(UnicodeScalar(key)!))
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Juxta")
        menu.addItem(item("About Juxta", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ","))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        menu.addItem(submenu(services))
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(item("Hide Juxta", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit Juxta", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New Comparison", #selector(AppDelegate.newComparison(_:)), "n"))
        menu.addItem(item("New Comparison from Clipboard", #selector(AppDelegate.newComparisonFromClipboard(_:)),
                          "n", [.command, .shift]))
        menu.addItem(item("Open…", #selector(AppDelegate.openDocument(_:)), "o"))
        let recent = NSMenu(title: "Open Recent")
        recent.delegate = RecentDocumentsMenu.shared
        RecentDocumentsMenu.shared.menuNeedsUpdate(recent)
        menu.addItem(submenu(recent))
        menu.addItem(.separator())
        menu.addItem(item("Open Left File…", #selector(CompareWindowController.chooseLeftFile(_:)), "1", [.command, .option]))
        menu.addItem(item("Open Right File…", #selector(CompareWindowController.chooseRightFile(_:)), "2", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Reload", #selector(CompareWindowController.reloadDocuments(_:)), "r"))
        menu.addItem(.separator())
        menu.addItem(item("Save Comparison…", #selector(CompareWindowController.saveComparison(_:)), "s"))
        menu.addItem(item("Export as HTML…", #selector(CompareWindowController.exportHTML(_:)), "e", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Copy", #selector(DiffPaneView.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(CompareWindowController.paste(_:)), "v"))
        menu.addItem(item("Paste as Left", #selector(CompareWindowController.pasteAsLeft(_:)), "v", [.command, .option]))
        menu.addItem(item("Paste as Right", #selector(CompareWindowController.pasteAsRight(_:)), "v", [.command, .option, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Select All", #selector(NSResponder.selectAll(_:)), "a"))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Next Change", #selector(CompareWindowController.goToNextChange(_:)),
                          arrow(NSDownArrowFunctionKey), [.command, .option]))
        menu.addItem(item("Previous Change", #selector(CompareWindowController.goToPreviousChange(_:)),
                          arrow(NSUpArrowFunctionKey), [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Ignore Whitespace", #selector(CompareWindowController.toggleIgnoreWhitespace(_:))))
        menu.addItem(item("Ignore Case", #selector(CompareWindowController.toggleIgnoreCase(_:))))
        menu.addItem(item("Ignore Timers", #selector(CompareWindowController.toggleIgnoreTimers(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Swap Sides", #selector(CompareWindowController.swapSides(_:)), "s", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Bigger", #selector(CompareWindowController.increaseFontSize(_:)), "+"))
        let biggerAlias = item("Bigger", #selector(CompareWindowController.increaseFontSize(_:)), "=")
        biggerAlias.isHidden = true
        biggerAlias.allowsKeyEquivalentWhenHidden = true
        menu.addItem(biggerAlias)
        menu.addItem(item("Smaller", #selector(CompareWindowController.decreaseFontSize(_:)), "-"))
        menu.addItem(item("Actual Size", #selector(CompareWindowController.resetFontSize(_:)), "0"))
        menu.addItem(.separator())
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
}

/// File › Open Recent, filled from `NSDocumentController`'s list when it opens. Juxta
/// doesn't use NSDocument, so AppKit doesn't manage this menu; its items open through
/// `AppDelegate.openFiles` like any other file.
final class RecentDocumentsMenu: NSObject, NSMenuDelegate {
    static let shared = RecentDocumentsMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for url in NSDocumentController.shared.recentDocumentURLs {
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: url.path),
                                  action: #selector(AppDelegate.openRecent(_:)), keyEquivalent: "")
            item.representedObject = url
            item.toolTip = (url.path as NSString).abbreviatingWithTildeInPath
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)),
                               keyEquivalent: "")
        clear.target = NSDocumentController.shared
        menu.addItem(clear)
    }
}
