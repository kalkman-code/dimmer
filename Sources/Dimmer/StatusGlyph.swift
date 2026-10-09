import AppKit

// Drawn in code from branding/glyph.svg and glyph-paused.svg (22-unit grid), so the app bundle
// needs no image resources beyond AppIcon.icns.
enum StatusGlyph {
    static func image(paused: Bool, increaseContrast: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let transform = NSAffineTransform()
            transform.scale(by: rect.width / 22)
            transform.concat()
            NSColor.black.setFill()
            NSColor.black.setStroke()
            if paused {
                let outline = polygon([(11, 2.75), (19.25, 11), (11, 19.25), (2.75, 11)])
                outline.lineWidth = increaseContrast ? 2 : 1.5
                outline.stroke()
            } else {
                polygon([(11, 2), (20, 11), (2, 11)]).fill()
                NSColor.black.withAlphaComponent(increaseContrast ? 0.7 : 0.35).setFill()
                polygon([(2, 11), (20, 11), (11, 20)]).fill()
                NSColor.black.setFill()
            }
            NSRect(x: 1, y: 11, width: 20, height: 1.5).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = paused ? L10n.string("Dimmer paused") : L10n.string("Dimmer active")
        return image
    }

    private static func polygon(_ points: [(CGFloat, CGFloat)]) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: points[0].0, y: points[0].1))
        points.dropFirst().forEach { path.line(to: NSPoint(x: $0.0, y: $0.1)) }
        path.close()
        return path
    }
}
