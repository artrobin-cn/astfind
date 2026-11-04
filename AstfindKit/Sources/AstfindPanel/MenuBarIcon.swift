import AppKit

/// Menu-bar mark: the finalized C1++ app icon reduced to its silhouette —
/// three source cards behind a lens — and drawn as a template image so it
/// follows the menu-bar appearance (light/dark) and stays crisp at any scale.
///
/// Geometry mirrors `docs/icon-concepts/flat/make-flat-icons.swift`
/// (`cStyleLoud`, the shipped C1++ variant); only the plate, colors and the
/// glass dot are dropped, because a menu-bar glyph must read at 16–18 pt.
///
/// Menu-bar space is capped vertically, so the canvas is wide (26×18) and the
/// C1++ composition is spread horizontally — cards nudged left, lens right —
/// to gain width without getting taller or distorting any shape.
enum MenuBarIcon {
    static let image: NSImage = makeImage()
    /// The status item must be at least as wide as the image, plus its side margins.
    static let statusItemLength: CGFloat = 26

    private static let canvas = NSSize(width: 26, height: 18)
    private static let padding: CGFloat = 1

    // C1++ composition, design units, spread horizontally for the menu bar.
    private static let designWidth: CGFloat = 600
    private static let designHeight: CGFloat = 408
    private static let designOrigin = CGPoint(x: 188, y: 292)
    private static let cardOrigin = CGPoint(x: 300, y: 404)
    private static let cardSize: CGFloat = 296
    private static let cardStep: CGFloat = 56
    private static let cardRadius: CGFloat = 62
    private static let cardCount = 3
    private static let cardKeyline: CGFloat = 34
    private static let lensCenter = CGPoint(x: 602, y: 512)
    private static let lensRadius: CGFloat = 132
    private static let lensWeight: CGFloat = 44
    private static let handleReach: CGFloat = 100
    private static let lensHalo: CGFloat = 18
    private static let diagonal: CGFloat = 0.70711

    private static func makeImage() -> NSImage {
        let image = NSImage(size: canvas, flipped: true) { _ in
            draw()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Astfind"
        return image
    }

    private static func draw() {
        guard let context = NSGraphicsContext.current else { return }
        let scale = min((canvas.width - padding * 2) / designWidth,
                        (canvas.height - padding * 2) / designHeight)
        let originX = (canvas.width - designWidth * scale) / 2
        let originY = (canvas.height - designHeight * scale) / 2

        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: originX + (x - designOrigin.x) * scale,
                    y: originY + (y - designOrigin.y) * scale)
        }
        func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
            NSRect(x: originX + (x - designOrigin.x) * scale,
                   y: originY + (y - designOrigin.y) * scale,
                   width: width * scale, height: height * scale)
        }
        func card(_ index: Int) -> NSBezierPath {
            let x = cardOrigin.x - CGFloat(index) * cardStep
            let y = cardOrigin.y - CGFloat(index) * cardStep
            return NSBezierPath(roundedRect: rect(x, y, cardSize, cardSize),
                                xRadius: cardRadius * scale, yRadius: cardRadius * scale)
        }
        func clear(_ body: () -> Void) {
            context.compositingOperation = .clear
            body()
            context.compositingOperation = .sourceOver
        }

        let ink = NSColor.black

        // Cards, back to front. Each front card cuts a keyline out of the one behind it.
        for index in stride(from: cardCount - 1, through: 0, by: -1) {
            let shape = card(index)
            if index < cardCount - 1 {
                clear {
                    shape.lineWidth = cardKeyline * scale
                    shape.stroke()
                }
            }
            ink.setFill()
            shape.fill()
        }

        // Lens: transparent glass, opaque ring and handle, separated from the cards by a halo.
        let center = point(lensCenter.x, lensCenter.y)
        let outer = (lensRadius + lensWeight / 2) * scale
        let inner = (lensRadius - lensWeight / 2) * scale
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - outer, y: center.y - outer,
                                               width: outer * 2, height: outer * 2))
        ring.appendOval(in: NSRect(x: center.x - inner, y: center.y - inner,
                                   width: inner * 2, height: inner * 2))
        ring.windingRule = .evenOdd

        let handle = NSBezierPath()
        handle.move(to: point(lensCenter.x + lensRadius * diagonal,
                              lensCenter.y + lensRadius * diagonal))
        handle.line(to: point(lensCenter.x + (lensRadius + handleReach) * diagonal,
                              lensCenter.y + (lensRadius + handleReach) * diagonal))
        handle.lineCapStyle = .round

        clear {
            let halo = NSBezierPath(ovalIn: NSRect(x: center.x - outer, y: center.y - outer,
                                                   width: outer * 2, height: outer * 2))
            halo.lineWidth = (lensWeight + lensHalo * 2) * scale
            halo.stroke()
            handle.lineWidth = (lensWeight + lensHalo * 2) * scale
            handle.stroke()
            NSBezierPath(ovalIn: NSRect(x: center.x - inner, y: center.y - inner,
                                        width: inner * 2, height: inner * 2)).fill()
        }

        ink.setFill()
        ring.fill()
        handle.lineWidth = lensWeight * scale
        ink.setStroke()
        handle.stroke()
    }
}
