import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [CompareWindowController] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let files = Self.fileArguments()
        if !files.isEmpty { openFiles(files) }
        // Files passed via Finder / `open` arrive through application(_:open:); only
        // show an empty window if nothing else opened one.
        DispatchQueue.main.async {
            if self.controllers.isEmpty { self.newComparison(nil) }
        }
        NSApp.activate()
        ScrollBench.runIfRequested()
        #if DEBUG
        DebugSnapshot.runIfRequested()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newComparison(nil) }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openFiles(urls)
    }

    /// Paths given on the command line (skipping AppKit's `-Key value` arguments).
    private static func fileArguments() -> [URL] {
        var urls: [URL] = []
        var arguments = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = arguments.next() {
            if argument.hasPrefix("-") {
                _ = arguments.next()
                continue
            }
            if FileManager.default.fileExists(atPath: argument) {
                urls.append(URL(fileURLWithPath: argument).standardizedFileURL)
            }
        }
        return urls
    }

    private var frontController: CompareWindowController? {
        (NSApp.keyWindow?.windowController ?? NSApp.mainWindow?.windowController)
            as? CompareWindowController
    }

    func openFiles(_ urls: [URL]) {
        var queue = urls[...]
        // Fill an empty frontmost window before opening new ones. A side still loading
        // isn't empty, or a second open in quick succession would replace the first.
        if let front = frontController, front.freeSides.count == 2, queue.count >= 2 {
            front.load(left: queue.popFirst(), right: queue.popFirst())
        } else if let front = frontController, let side = front.freeSides.first, queue.count == 1 {
            front.load(queue.removeFirst(), into: side)
        }
        while !queue.isEmpty {
            let controller = makeController()
            controller.load(left: queue.popFirst(), right: queue.popFirst())
        }
    }

    @discardableResult
    private func makeController() -> CompareWindowController {
        let controller = CompareWindowController()
        controller.onClose = { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
        }
        if let previous = frontController?.window ?? controllers.last?.window {
            controller.window?.setFrame(previous.frame, display: false)
            controller.window?.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY))
        } else {
            controller.window?.center()
        }
        controllers.append(controller)
        controller.showWindow(nil)
        return controller
    }

    @objc func newComparison(_ sender: Any?) {
        makeController()
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(sender)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose two files to compare"
        panel.prompt = "Compare"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.openFiles(panel.urls)
        }
    }
}
