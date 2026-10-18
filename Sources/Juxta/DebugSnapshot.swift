#if DEBUG
import AppKit
import JuxtaCore

/// Development aid: `JUXTA_SNAPSHOT=/path/prefix` renders the front window to PNGs
/// (initial state, then after "next change" steps given by JUXTA_STEPS) and quits.
/// `JUXTA_SLOW_COMPARE=<seconds>` keeps the comparison running to capture the progress bar.
/// `JUXTA_ACTIONS=next,swap,reload,prev,bigger,smaller,actual,select,selectall` runs those steps instead
/// of JUXTA_STEPS "next"s (`select` selects characters on the left and the change on the right);
/// `JUXTA_HC=1` uses the Increase Contrast appearance (with JUXTA_DARK, the dark one);
/// `JUXTA_AX=1` prints what VoiceOver would see after each capture; `JUXTA_SETTINGS=1` also
/// captures the Settings window.
enum DebugSnapshot {
    private static var actions: [String] = []
    private static var dumpsAccessibility = false

    static func runIfRequested() {
        guard let prefix = ProcessInfo.processInfo.environment["JUXTA_SNAPSHOT"] else { return }
        let env = ProcessInfo.processInfo.environment
        actions = env["JUXTA_ACTIONS"]?.split(separator: ",").map(String.init)
            ?? Array(repeating: "next", count: Int(env["JUXTA_STEPS"] ?? "0") ?? 0)
        dumpsAccessibility = env["JUXTA_AX"] != nil
        let steps = actions.count
        NSApp.appearance = NSAppearance(named: env["JUXTA_DARK"] != nil ? .darkAqua : .aqua)
        // Only Juxta's own colors; system colors follow the real setting.
        Theme.forcesHighContrast = env["JUXTA_HC"] != nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard let window = NSApp.windows.first(where: { $0.windowController is CompareWindowController }),
                  let controller = window.windowController as? CompareWindowController else { exit(1) }
            print("subtitle:", window.subtitle)
            capture(window, "\(prefix)-0.png")
            // JUXTA_SETTINGS: also capture the Settings window.
            if ProcessInfo.processInfo.environment["JUXTA_SETTINGS"] != nil {
                SettingsWindowController.shared.showWindow(nil)
                if let settings = SettingsWindowController.shared.window {
                    settings.contentView?.wantsLayer = true
                    capture(settings, "\(prefix)-settings.png")
                }
            }
            // JUXTA_CANCEL: cancel what is running (with JUXTA_SLOW_COMPARE) and capture that.
            guard ProcessInfo.processInfo.environment["JUXTA_CANCEL"] != nil else {
                return step(1, of: steps, controller, window, prefix)
            }
            controller.cancelOperation(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                print("subtitle:", window.subtitle)
                capture(window, "\(prefix)-cancelled.png")
                step(1, of: steps, controller, window, prefix)
            }
        }
    }

    /// Captures a while after each step, so background work it starts (long-line
    /// highlights, and the scrolling that waits on them) shows up.
    private static func step(_ n: Int, of steps: Int, _ controller: CompareWindowController,
                             _ window: NSWindow, _ prefix: String) {
        guard n <= steps else { exit(0) }
        let action = actions[n - 1]
        controller.lastAnnouncement = nil
        switch action {
        case "prev": controller.goToPreviousChange(nil)
        case "swap": controller.swapSides(nil)
        case "reload": controller.reloadDocuments(nil)
        case "bigger": controller.increaseFontSize(nil)
        case "smaller": controller.decreaseFontSize(nil)
        case "actual": controller.resetFontSize(nil)
        case "select": select(controller)
        case "selectall": controller.debugPanes[0].selectAll(nil)
        default: controller.goToNextChange(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            print("step \(n) \(action) subtitle:", window.subtitle)
            if dumpsAccessibility {
                print("announcement:", controller.lastAnnouncement ?? "none")
            }
            capture(window, "\(prefix)-\(n).png")
            step(n + 1, of: steps, controller, window, prefix)
        }
    }

    /// In the change navigated to (or the first), characters from the first row to two
    /// rows on in the left pane, and the whole change in the right one.
    private static func select(_ controller: CompareWindowController) {
        let p = controller.presentation
        guard let hunk = p.currentHunk ?? (p.result.hunks.isEmpty ? nil : 0),
              let right = p.right else { return }
        let rows = p.result.hunks[hunk].rows
        let panes = controller.debugPanes
        panes[0].selection = TextSelection(anchor: .init(row: rows.lowerBound, offset: 3),
                                           head: .init(row: rows.lowerBound + 2, offset: 9))
        panes[1].selection = TextSelection(rows: rows.lowerBound, to: rows.upperBound - 1, in: p.result,
                                           on: \.right, lines: right.lines)
    }

    /// Labels of the panes' visible rows and the change map, as VoiceOver gets them.
    private static func dumpAccessibility(_ window: NSWindow) {
        guard dumpsAccessibility, let content = window.contentView else { return }
        func walk(_ view: NSView) {
            if view.isAccessibilityElement() {
                if let pane = view as? DiffPaneView {
                    let rows = pane.accessibilityChildren() ?? []
                    print("ax \(pane.accessibilityRole()!.rawValue) \"\(pane.accessibilityLabel() ?? "")\" \(rows.count) rows")
                    for case let row as NSAccessibilityElement in rows.prefix(14) {
                        print("  \(row.accessibilityRole()!.rawValue) \(row.accessibilityFrame()) \(row.accessibilityLabel() ?? "")")
                    }
                } else if view is ChangeMapView {
                    print("ax \(view.accessibilityRole()!.rawValue) \"\(view.accessibilityLabel() ?? "")\"",
                          "value: \(view.accessibilityValueDescription() ?? "")")
                }
            }
            view.subviews.forEach(walk)
        }
        walk(content)
    }

    private static func dump(_ view: NSView, _ depth: Int) {
        guard depth < 5 else { return }
        print(String(repeating: "  ", count: depth), type(of: view), view.frame, view.isHidden ? "hidden" : "")
        view.subviews.forEach { dump($0, depth + 1) }
    }

    private static func captureView(_ view: NSView, _ path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.visibleRect) else { return }
        view.cacheDisplay(in: view.visibleRect, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Renders the composited layer tree (what is actually on screen), not the views'
    /// draw methods in isolation — the latter hides views painting over each other.
    private static func capture(_ window: NSWindow, _ path: String) {
        guard let view = window.contentView, let layer = view.layer else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        CATransaction.flush()
        let scale = window.backingScaleFactor
        guard let ctx = CGContext(
            data: nil, width: Int(view.bounds.width * scale), height: Int(view.bounds.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        guard let image = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
        dumpAccessibility(window)
    }
}
#endif
