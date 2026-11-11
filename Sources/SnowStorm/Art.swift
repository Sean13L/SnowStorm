import AppKit
import SpriteKit

/// Procedurally drawn art: no bundled images, so there are no licensing questions.
@MainActor
enum Art {
    /// Soft round flake with a faint blue rim so it stays visible over white windows.
    static let flake: SKTexture = {
        let size: CGFloat = 32
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let colors = [
                NSColor(white: 1, alpha: 1).cgColor,
                NSColor(white: 1, alpha: 0.95).cgColor,
                NSColor(calibratedRed: 0.72, green: 0.80, blue: 0.93, alpha: 0.55).cgColor,
                NSColor(calibratedRed: 0.72, green: 0.80, blue: 0.93, alpha: 0).cgColor,
            ] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 0.72, 1])!
            let c = CGPoint(x: size / 2, y: size / 2)
            ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: size / 2, options: [])
            return true
        }
        return SKTexture(image: image)
    }()

    /// One icicle, drawn once and stretched to each icicle's width and length.
    static let icicle: SKTexture = {
        let w: CGFloat = 12, h: CGFloat = 48
        let image = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0.5, y: h))
            path.curve(to: NSPoint(x: w / 2, y: 0.5), controlPoint1: NSPoint(x: w * 0.2, y: h * 0.45), controlPoint2: NSPoint(x: w * 0.45, y: h * 0.2))
            path.curve(to: NSPoint(x: w - 0.5, y: h), controlPoint1: NSPoint(x: w * 0.55, y: h * 0.2), controlPoint2: NSPoint(x: w * 0.8, y: h * 0.45))
            path.close()
            NSColor(calibratedRed: 0.86, green: 0.94, blue: 1, alpha: 0.92).setFill()
            path.fill()
            NSColor(calibratedRed: 0.58, green: 0.74, blue: 0.95, alpha: 0.9).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
        return SKTexture(image: image)
    }()

    /// Three stacked outline circles; a template image so macOS tints it for light/dark menu bars.
    static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let balls: [(CGFloat, CGFloat)] = [(4.8, 4.1), (10.8, 2.9), (14.9, 2.0)]
            for (y, r) in balls {
                let path = NSBezierPath(ovalIn: NSRect(x: 9 - r, y: y - r, width: r * 2, height: r * 2))
                path.lineWidth = 1.4
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "SnowStorm"
        return image
    }

    /// Renders the 1024×1024 app icon (used by build.sh to make AppIcon.icns).
    static func renderAppIcon(to url: URL) throws {
        let px = 1024
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
        NSGradient(starting: NSColor(calibratedRed: 0.36, green: 0.55, blue: 0.88, alpha: 1),
                   ending: NSColor(calibratedRed: 0.07, green: 0.11, blue: 0.30, alpha: 1))!.draw(in: tile, angle: 90)
        tile.addClip()

        // Falling flakes from a fixed seed so the icon is reproducible.
        var seed: UInt64 = 0x5EED
        func rand() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(seed >> 33) / CGFloat(1 << 31)
        }
        for _ in 0..<46 {
            let r = 4 + rand() * 9
            NSColor(white: 1, alpha: 0.55 + rand() * 0.45).setFill()
            NSBezierPath(ovalIn: NSRect(x: 110 + rand() * 800, y: 330 + rand() * 590, width: r * 2, height: r * 2)).fill()
        }

        // Snow bank.
        NSColor(calibratedRed: 0.86, green: 0.91, blue: 0.99, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: -60, y: -40, width: 1144, height: 400)).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: -40, y: -60, width: 1104, height: 400)).fill()

        func ball(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
            NSColor(calibratedRed: 0.80, green: 0.86, blue: 0.96, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)).fill()
            NSColor.white.setFill()
            let ri = r * 0.86
            NSBezierPath(ovalIn: NSRect(x: cx - ri - r * 0.1, y: cy - ri + r * 0.1, width: ri * 2, height: ri * 2)).fill()
        }
        ball(512, 360, 150)
        ball(512, 565, 108)
        ball(512, 725, 78)

        // Scarf.
        NSColor(calibratedRed: 0.86, green: 0.16, blue: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 412, y: 640, width: 200, height: 40), xRadius: 20, yRadius: 20).fill()
        NSBezierPath(roundedRect: NSRect(x: 540, y: 560, width: 40, height: 100), xRadius: 16, yRadius: 16).fill()

        // Face.
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 478, y: 738, width: 18, height: 18)).fill()
        NSBezierPath(ovalIn: NSRect(x: 528, y: 738, width: 18, height: 18)).fill()
        for y in [585.0, 535.0] { NSBezierPath(ovalIn: NSRect(x: 503, y: y, width: 18, height: 18)).fill() }
        NSColor(calibratedRed: 0.97, green: 0.52, blue: 0.12, alpha: 1).setFill()
        let carrot = NSBezierPath()
        carrot.move(to: NSPoint(x: 512, y: 728)); carrot.line(to: NSPoint(x: 512, y: 708)); carrot.line(to: NSPoint(x: 590, y: 712)); carrot.close()
        carrot.fill()

        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
