// Renders the app icon: two panes with colored diff bars.  Usage: swift make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.24, blue: 0.33, alpha: 1),
               ending: NSColor(srgbRed: 0.09, green: 0.11, blue: 0.16, alpha: 1))!.draw(in: shape, angle: 90)

    let paneWidth: CGFloat = 310
    for (index, x) in [CGFloat(180), 534].enumerated() {
        let pane = NSRect(x: x, y: 190, width: paneWidth, height: 644)
        NSColor(white: 1, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: pane, xRadius: 40, yRadius: 40).fill()
        // (color, left width fraction, right width fraction) per row; nil color = plain text
        let rows: [(NSColor?, CGFloat, CGFloat)] = [
            (nil, 0.75, 0.75), (nil, 0.55, 0.55),
            (.systemRed, 0.65, 0), (nil, 0.7, 0.7),
            (.systemBlue, 0.5, 0.62), (nil, 0.6, 0.6),
            (.systemGreen, 0, 0.72), (nil, 0.45, 0.45),
        ]
        for (r, row) in rows.enumerated() {
            let y = pane.minY + 44 + CGFloat(r) * 72
            let fraction = index == 0 ? row.1 : row.2
            if let color = row.0 {
                let band = NSRect(x: pane.minX, y: y - 14, width: paneWidth, height: 64)
                (fraction == 0 ? NSColor(white: 0.88, alpha: 1) : color.withAlphaComponent(0.25)).setFill()
                band.fill()
            }
            guard fraction > 0 else { continue }
            (row.0 ?? NSColor(white: 0.55, alpha: 1)).setFill()
            NSBezierPath(roundedRect: NSRect(x: pane.minX + 36, y: y + 6, width: (paneWidth - 72) * fraction, height: 24),
                         xRadius: 12, yRadius: 12).fill()
        }
    }
    return true
}
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
