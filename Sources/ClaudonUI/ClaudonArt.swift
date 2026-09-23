import AppKit

/// Claudon's eared squircle, drawn in code so it stays sharp at every size.
public enum ClaudonArt {
    // MARK: Menu bar

    /// One color per 10% step: dark blue, blue, green, orange, red.
    public static let stageColors: [UInt32] = [
        0x1B3A8C, 0x2456C4, 0x2A78D6, 0x1A9AA8, 0x22A33A,
        0x7DB52A, 0xE2A21A, 0xF0821C, 0xE35A2C, 0xD03B3B,
    ]
    /// Navy disappears on a dark menu bar, so the first two stages lighten there.
    public static let darkStageColors: [UInt32] = [0x4A6FD8, 0x3F72E8] + stageColors.dropFirst(2)

    /// The color for a stage (0 through 9) on a light or dark ground.
    public static func stageColor(_ stage: Int, dark: Bool) -> UInt32 {
        (dark ? darkStageColors : stageColors)[min(max(stage, 0), stageColors.count - 1)]
    }

    /// The glyph lives in an 18 x 18 box with y pointing down: a squircle outline with two ears.
    public static let glyphBox: CGFloat = 18
    public static let glyphStroke: CGFloat = 2.5

    /// The squircle, clockwise from top center so a partial stroke fills like a gauge.
    public static let squircle: CGPath = {
        let (left, top, right, bottom): (CGFloat, CGFloat, CGFloat, CGFloat) = (3.2, 5, 14.8, 16.6)
        let k: CGFloat = 4.6, c = k * 0.22
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 9, y: top))
        path.addLine(to: CGPoint(x: right - k, y: top))
        path.addCurve(to: CGPoint(x: right, y: top + k), control1: CGPoint(x: right - c, y: top),
                      control2: CGPoint(x: right, y: top + c))
        path.addLine(to: CGPoint(x: right, y: bottom - k))
        path.addCurve(to: CGPoint(x: right - k, y: bottom), control1: CGPoint(x: right, y: bottom - c),
                      control2: CGPoint(x: right - c, y: bottom))
        path.addLine(to: CGPoint(x: left + k, y: bottom))
        path.addCurve(to: CGPoint(x: left, y: bottom - k), control1: CGPoint(x: left + c, y: bottom),
                      control2: CGPoint(x: left, y: bottom - c))
        path.addLine(to: CGPoint(x: left, y: top + k))
        path.addCurve(to: CGPoint(x: left + k, y: top), control1: CGPoint(x: left, y: top + c),
                      control2: CGPoint(x: left + c, y: top))
        path.addLine(to: CGPoint(x: 9, y: top))
        return path
    }()

    private static let squircleCenterY: CGFloat = (5 + 16.6) / 2

    /// Everything the glyph paints: the stroked outline and the ears.
    private static var glyphBounds: CGRect {
        squircle.boundingBoxOfPath.insetBy(dx: -glyphStroke / 2, dy: -glyphStroke / 2)
            .union(glyphEars.boundingBoxOfPath)
    }

    private static let squircleLength: CGFloat = length(of: squircle)

    public static let glyphEars: CGPath = {
        let ear = CGMutablePath()
        ear.addLines(between: [CGPoint(x: 2.4, y: 7.2), CGPoint(x: 2.7, y: 1.2), CGPoint(x: 7.6, y: 4.4)])
        ear.closeSubpath()
        var flip = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: glyphBox, ty: 0)
        ear.addPath(ear.copy(using: &flip) ?? ear)
        return ear
    }()

    /// Template glyph for when there's no current usage: the full outline, in the menu bar's ink.
    public static func menuBarGlyph(size: CGFloat = 18) -> NSImage {
        let image = glyphImage(size: size) { ctx, _ in
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(glyphEars)
            ctx.fillPath()
            strokeSquircle(in: ctx, color: NSColor.black.cgColor)
        }
        image.isTemplate = true
        image.accessibilityDescription = "Claudon"
        return image
    }

    /// Colored glyph for a usage stage (0 through 9). The ears always carry the stage color and
    /// the outline fills clockwise from the top, one tenth per stage, over a faint track.
    /// `dark` forces a menu bar appearance; by default it follows the one being drawn into.
    public static func menuBarGlyph(stage: Int, dark: Bool? = nil, size: CGFloat = 18) -> NSImage {
        let stage = min(max(stage, 0), stageColors.count - 1)
        let image = glyphImage(size: size) { ctx, drawingDark in
            let isDark = dark ?? drawingDark
            let color = rgb(stageColor(stage, dark: isDark))
            strokeSquircle(in: ctx, color: isDark ? CGColor(gray: 1, alpha: 0.28) : CGColor(gray: 0, alpha: 0.22))
            let filled = squircleLength * CGFloat(stage + 1) / CGFloat(stageColors.count)
            ctx.setLineDash(phase: 0, lengths: [filled, squircleLength * 2])
            strokeSquircle(in: ctx, color: color)
            ctx.setFillColor(color)
            ctx.addPath(glyphEars)
            ctx.fillPath()
        }
        image.accessibilityDescription = "Claudon, \(stage * 10) to \(stage * 10 + 10)% used"
        return image
    }

    private static func glyphImage(size: CGFloat, draw: @escaping (CGContext, Bool) -> Void) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ctx.scaleBy(x: size / glyphBox, y: size / glyphBox)
            draw(ctx, dark)
            return true
        }
    }

    private static func strokeSquircle(in ctx: CGContext, color: CGColor) {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(glyphStroke)
        ctx.setLineCap(.round)
        ctx.addPath(squircle)
        ctx.strokePath()
    }

    /// Arc length of a path made of lines and cubic curves, with curves sampled finely.
    private static func length(of path: CGPath) -> CGFloat {
        var total: CGFloat = 0
        var current = CGPoint.zero
        path.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                current = points[0]
            case .addLineToPoint:
                total += hypot(points[0].x - current.x, points[0].y - current.y)
                current = points[0]
            case .addCurveToPoint:
                let (p0, p1, p2, p3) = (current, points[0], points[1], points[2])
                var previous = p0
                for step in 1...64 {
                    let t = CGFloat(step) / 64, u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    let point = CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                                        y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
                    total += hypot(point.x - previous.x, point.y - previous.y)
                    previous = point
                }
                current = p3
            default:
                break
            }
        }
        return total
    }

    // MARK: App icon

    public static func appIcon(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawIcon(in: ctx, size: size)
            return true
        }
    }

    /// Draws the full-color icon into a y-down context `size` points square: the eared squircle
    /// on a transparent ground, colored with every stage clockwise from the top.
    public static func drawIcon(in ctx: CGContext, size: CGFloat) {
        // Fit the glyph, stroke and ears included, to the 824 point macOS icon grid.
        let bounds = glyphBounds
        let scale = size * 824 / 1024 / max(bounds.width, bounds.height)
        ctx.saveGState()
        ctx.translateBy(x: size / 2 - bounds.midX * scale, y: size / 2 - bounds.midY * scale)
        ctx.scaleBy(x: scale, y: scale)
        // Ears and outline clip separately: combined, their opposite windings cancel where they overlap.
        let outline = squircle.copy(strokingWithWidth: glyphStroke, lineCap: .round, lineJoin: .round, miterLimit: 10)
        for shape in [glyphEars, outline] {
            ctx.saveGState()
            ctx.addPath(shape)
            ctx.clip()
            drawSweep(in: ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    /// Every stage color clockwise from the top, as thin wedges since Core Graphics has no conic
    /// gradient.
    private static func drawSweep(in ctx: CGContext) {
        let center = CGPoint(x: 9, y: squircleCenterY)
        let slices = 720
        for slice in 0..<slices {
            // y points down, so angles run clockwise; -pi/2 is straight up.
            let start = -CGFloat.pi / 2 + 2 * .pi * CGFloat(slice) / CGFloat(slices)
            let end = start + 2 * .pi / CGFloat(slices) + 0.01
            let wedge = CGMutablePath()
            wedge.move(to: center)
            wedge.addArc(center: center, radius: 20, startAngle: start, endAngle: end, clockwise: false)
            wedge.closeSubpath()
            ctx.setFillColor(sweepColor(at: (CGFloat(slice) + 0.5) / CGFloat(slices)))
            ctx.addPath(wedge)
            ctx.fillPath()
        }
    }

    /// The stage colors blended evenly from 0 (dark blue) to 1 (red).
    private static func sweepColor(at t: CGFloat) -> CGColor {
        let position = min(max(t, 0), 1) * CGFloat(stageColors.count - 1)
        let index = min(Int(position), stageColors.count - 2)
        let mix = position - CGFloat(index)
        func channels(_ hex: UInt32) -> [CGFloat] {
            [CGFloat((hex >> 16) & 0xFF), CGFloat((hex >> 8) & 0xFF), CGFloat(hex & 0xFF)].map { $0 / 255 }
        }
        let from = channels(stageColors[index]), to = channels(stageColors[index + 1])
        let blended = zip(from, to).map { $0 + ($1 - $0) * mix }
        return CGColor(srgbRed: blended[0], green: blended[1], blue: blended[2], alpha: 1)
    }

    /// Writes the PNGs `iconutil` turns into AppIcon.icns.
    public static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sizes: [(name: String, pixels: Int)] = [
            ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
            ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024),
        ]
        for (name, pixels) in sizes {
            guard let png = pngData(pixels: pixels, draw: { drawIcon(in: $0, size: CGFloat(pixels)) }) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try png.write(to: directory.appendingPathComponent("icon_\(name).png"))
        }
    }

    /// Renders into a square bitmap with a y-down context.
    public static func pngData(pixels: Int, draw: (CGContext) -> Void) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let ctx = context.cgContext
        ctx.translateBy(x: 0, y: CGFloat(pixels))
        ctx.scaleBy(x: 1, y: -1)
        draw(ctx)
        context.flushGraphics()
        return rep.representation(using: .png, properties: [:])
    }

    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
