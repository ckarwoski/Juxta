import AppKit

/// Performance aid: `JUXTA_SCROLLBENCH=<screens> Juxta left right` logs how long after
/// process start the first comparison is drawn, then pages down that many screens, timing
/// each one's word highlights and drawing, and quits. Not limited to debug builds, since
/// release timings are the ones that matter.
enum ScrollBench {
    static func runIfRequested() {
        guard let value = ProcessInfo.processInfo.environment["JUXTA_SCROLLBENCH"] else { return }
        waitForResult(screens: Int(value) ?? 100)
    }

    private static func now() -> Double {
        var time = timeval()
        gettimeofday(&time, nil)
        return Double(time.tv_sec) + Double(time.tv_usec) / 1e6
    }

    /// Includes dyld and AppKit startup, which a timestamp taken in main would miss.
    private static func processStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let start = info.kp_proc.p_starttime
        return Double(start.tv_sec) + Double(start.tv_usec) / 1e6
    }

    /// Polls until both files are loaded and compared; the comparison runs in the background.
    private static func waitForResult(screens: Int, started: Double = now()) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) {
            guard let controller = NSApp.windows.lazy.compactMap({ $0.windowController as? CompareWindowController })
                .first(where: { !$0.hasEmptySide && !$0.isComparing }),
                  let window = controller.window else {
                // Without two files to compare there is nothing to measure.
                if now() - started > 60 {
                    print("scroll bench: no comparison after 60 s; pass two files")
                    exit(1)
                }
                return waitForResult(screens: screens, started: started)
            }
            window.displayIfNeeded()
            print(String(format: "first paint: %.0f ms after launch (%@)",
                         (now() - processStart()) * 1000, window.subtitle))
            scroll(controller, window, screens: screens)
            exit(0)
        }
    }

    private static func scroll(_ controller: CompareWindowController, _ window: NSWindow, screens: Int) {
        let p = controller.presentation
        // Drawing into a bitmap runs draw(_:) synchronously; the window's own display is
        // deferred to Core Animation and can't be timed directly.
        let panes = window.contentView.map(diffPanes) ?? []
        let bitmaps = panes.map { $0.bitmapImageRepForCachingDisplay(in: $0.visibleRect) }
        var highlights: [Double] = [], draws: [Double] = []
        for screen in 1..<max(screens + 1, 1) {
            guard let metrics = controller.scrollMetrics,
                  metrics.offset + metrics.visible < metrics.total else { break }
            controller.scroll(toY: CGFloat(screen) * metrics.visible)
            guard let shown = controller.scrollMetrics else { break }
            // Highlights first, so they are timed apart from drawing.
            let visible = Int(shown.offset / p.lineHeight)..<Int(ceil((shown.offset + shown.visible) / p.lineHeight))
            var start = now()
            for row in visible where row < p.result.rows.count { _ = p.inlineChanges(row: row) }
            highlights.append(now() - start)
            start = now()
            for (pane, bitmap) in zip(panes, bitmaps) {
                if let bitmap { pane.cacheDisplay(in: pane.visibleRect, to: bitmap) }
            }
            draws.append(now() - start)
        }
        guard !draws.isEmpty else { return }
        let totals = zip(highlights, draws).map(+)
        func ms(_ values: [Double]) -> String {
            String(format: "avg %.2f ms, max %.2f ms", values.reduce(0, +) / Double(max(values.count, 1)) * 1000,
                   (values.max() ?? 0) * 1000)
        }
        print("\(totals.count) screens of \(panes.count) panes; highlights \(ms(highlights)); draw \(ms(draws)); total \(ms(totals))")
    }

    private static func diffPanes(in view: NSView) -> [DiffPaneView] {
        (view as? DiffPaneView).map { [$0] } ?? view.subviews.flatMap(diffPanes)
    }
}
