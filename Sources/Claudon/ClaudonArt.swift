import AppKit

/// Claudon's creature, drawn in code so it stays sharp at every size.
///
/// Every shape lives in a 100 x 100 box with y pointing down.
enum ClaudonArt {
    static let leftEye = CGRect(x: 31.5, y: 52, width: 11, height: 15)
    static let rightEye = CGRect(x: 57.5, y: 52, width: 11, height: 15)
    /// The area the silhouette covers, used to center it.
    static let silhouetteBounds = CGRect(x: 12, y: 8, width: 76, height: 84)

    /// Body and ears, as separate shapes so overlapping paths can't cancel out.
    static func silhouetteParts() -> [CGPath] {
        let body = CGPath(ellipseIn: CGRect(x: 13, y: 30, width: 74, height: 62), transform: nil)
        let leftEar = CGMutablePath()
        leftEar.move(to: CGPoint(x: 19, y: 52))
        leftEar.addQuadCurve(to: CGPoint(x: 21, y: 8), control: CGPoint(x: 12, y: 26))
        leftEar.addQuadCurve(to: CGPoint(x: 47, y: 33), control: CGPoint(x: 37, y: 15))
        leftEar.closeSubpath()
        return [body, leftEar, mirrored(leftEar)]
    }

    static func innerEars() -> [CGPath] {
        let ear = CGMutablePath()
        ear.move(to: CGPoint(x: 24, y: 45))
        ear.addQuadCurve(to: CGPoint(x: 24.5, y: 17), control: CGPoint(x: 19, y: 30))
        ear.addQuadCurve(to: CGPoint(x: 41, y: 34), control: CGPoint(x: 33, y: 21))
        ear.closeSubpath()
        return [ear, mirrored(ear)]
    }

    /// A four-point sparkle on the forehead.
    static func spark() -> CGPath {
        let center = CGPoint(x: 50, y: 41)
        let outer: CGFloat = 7, inner: CGFloat = 2
        let path = CGMutablePath()
        for i in 0..<8 {
            let angle = CGFloat(i) * .pi / 4 - .pi / 2
            let radius = i.isMultiple(of: 2) ? outer : inner
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    private static func mirrored(_ path: CGPath) -> CGPath {
        var flip = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 100, ty: 0)
        return path.copy(using: &flip) ?? path
    }

    // MARK: Menu bar

    /// Template image for the menu bar: the silhouette with the eyes cut out.
    static func menuBarGlyph(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let art = silhouetteBounds
            let scale = (size - 2) / art.height
            ctx.translateBy(x: (size - art.width * scale) / 2 - art.minX * scale,
                            y: (size - art.height * scale) / 2 - art.minY * scale)
            ctx.scaleBy(x: scale, y: scale)
            ctx.setFillColor(NSColor.black.cgColor)
            for part in silhouetteParts() {
                ctx.addPath(part)
                ctx.fillPath()
            }
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: leftEye)
            ctx.fillEllipse(in: rightEye)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Claudon"
        return image
    }

    // MARK: App icon

    static func appIcon(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawIcon(in: ctx, size: size)
            return true
        }
    }

    /// Draws the full-color icon into a y-down context `size` points square.
    static func drawIcon(in ctx: CGContext, size: CGFloat) {
        let unit = size / 1024
        // macOS icon grid: an 824 point tile centered on a 1024 canvas.
        let tile = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 185 * unit, cornerHeight: 185 * unit, transform: nil))
        ctx.clip()
        let colors = [rgb(0xFFA15E), rgb(0xE85A3A)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                     locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY),
                                   options: [])
        }
        ctx.restoreGState()

        let scale = 6.3 * unit
        ctx.saveGState()
        ctx.translateBy(x: 512 * unit - 50 * scale, y: 530 * unit - 50 * scale)
        ctx.scaleBy(x: scale, y: scale)
        drawCreature(in: ctx)
        ctx.restoreGState()
    }

    /// The colored creature, in art-box coordinates.
    static func drawCreature(in ctx: CGContext) {
        let ink = rgb(0x2B1D16)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.14))
        ctx.fillEllipse(in: CGRect(x: 22, y: 87, width: 56, height: 9))

        ctx.setFillColor(rgb(0xFFF4E8))
        for part in silhouetteParts() {
            ctx.addPath(part)
            ctx.fillPath()
        }
        ctx.setFillColor(rgb(0xF7A58C))
        for ear in innerEars() {
            ctx.addPath(ear)
            ctx.fillPath()
        }
        ctx.setFillColor(rgb(0xFF8A80, alpha: 0.55))
        ctx.fillEllipse(in: CGRect(x: 19, y: 67, width: 13, height: 8))
        ctx.fillEllipse(in: CGRect(x: 68, y: 67, width: 13, height: 8))

        ctx.setFillColor(ink)
        ctx.fillEllipse(in: leftEye)
        ctx.fillEllipse(in: rightEye)
        ctx.setFillColor(rgb(0xFFFFFF))
        ctx.fillEllipse(in: CGRect(x: 36.2, y: 54.5, width: 4.6, height: 4.6))
        ctx.fillEllipse(in: CGRect(x: 62.2, y: 54.5, width: 4.6, height: 4.6))

        let mouth = CGMutablePath()
        mouth.move(to: CGPoint(x: 45, y: 71.5))
        mouth.addQuadCurve(to: CGPoint(x: 55, y: 71.5), control: CGPoint(x: 50, y: 77))
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(2.6)
        ctx.setLineCap(.round)
        ctx.addPath(mouth)
        ctx.strokePath()

        ctx.setFillColor(rgb(0xF07A45))
        ctx.addPath(spark())
        ctx.fillPath()
    }

    /// Writes the PNGs `iconutil` turns into AppIcon.icns.
    static func writeIconset(to directory: URL) throws {
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
    static func pngData(pixels: Int, draw: (CGContext) -> Void) -> Data? {
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
