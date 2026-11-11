import AppKit
import SpriteKit
import Metal

/// `SnowStorm --preview out.png`: simulates a couple of minutes of snow over fake
/// windows and a Dock, then writes a PNG. Handy for checking the look without
/// granting Screen Recording.
@MainActor
enum Preview {
    static func render(to url: URL) {
        Snowman.quickThrows = true
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 760)
        let scene = SnowScene(screenFrame: frame)
        let surfaces = [
            Surface(id: "dock", kind: .dock, rect: CGRect(x: 300, y: 0, width: 600, height: 64), order: -1000),
            Surface(id: "w1", kind: .window, rect: CGRect(x: 140, y: 230, width: 520, height: 380), order: 1),
            Surface(id: "w2", kind: .window, rect: CGRect(x: 520, y: 140, width: 520, height: 330), order: 2),
            Surface(id: "wg1", kind: .widget, rect: CGRect(x: 1012, y: 556, width: 180, height: 180).insetBy(dx: SurfaceTracker.widgetCardInset, dy: SurfaceTracker.widgetCardInset), order: 10_001),
            Surface(id: "wg2", kind: .widget, rect: CGRect(x: 1012, y: 376, width: 180, height: 180).insetBy(dx: SurfaceTracker.widgetCardInset, dy: SurfaceTracker.widgetCardInset), order: 10_002),
            Surface(id: "icon", kind: .desktopIcon, rect: CGRect(x: 760, y: 600, width: 64, height: 80), order: 20_000),
            Surface(id: "menubar0", kind: .menuBar, rect: CGRect(x: 0, y: 736, width: 1200, height: 24), order: -2000),
        ]
        let view = SKView(frame: NSRect(origin: .zero, size: frame.size))
        view.presentScene(scene)
        scene.apply(surfaces: surfaces)
        var t: TimeInterval = 1
        let seconds = Int(ProcessInfo.processInfo.environment["PREVIEW_SECONDS"] ?? "") ?? 140
        for _ in 0..<(60 * seconds) {
            scene.update(t)
            t += 1.0 / 60
        }
        print("simulated \(Int(t))s: \(scene.spillCount) clumps spilled off full piles, \(scene.clumpLandings) falling clumps settled on a surface below")
        // Backdrop so white snow is visible in the PNG: two "windows" and a Dock.
        let backdrop = SKNode()
        backdrop.zPosition = -100
        for s in surfaces where s.kind != .menuBar && s.kind != .ground {
            let n = SKShapeNode(rect: s.rect, cornerRadius: s.kind.cornerRadius)
            n.fillColor = s.kind == .widget ? NSColor(calibratedRed: 0.25, green: 0.3, blue: 0.4, alpha: 1) : s.kind == .window ? NSColor(calibratedWhite: 0.16 + CGFloat(s.order) * 0.05, alpha: 1)
                                            : NSColor(calibratedWhite: 0.3, alpha: 0.9)
            n.strokeColor = NSColor(white: 0.4, alpha: 1)
            n.zPosition = -50 - CGFloat(min(s.order, 50))
            backdrop.addChild(n)
        }
        let sky = SKSpriteNode(color: NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.27, alpha: 1), size: frame.size)
        sky.anchorPoint = .zero
        sky.zPosition = -200
        backdrop.addChild(sky)
        scene.addChild(backdrop)
        scene.backgroundColor = .black
        writeMetalFrame(scene: scene, size: frame.size, to: url.deletingPathExtension().appendingPathExtension("metal.png"))
        // SKActions (the snowman) only run inside a live view, so host it in a
        // nearly invisible window and let the run loop tick for a while.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: frame.width, height: frame.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.alphaValue = 0.02
        window.ignoresMouseEvents = true
        window.contentView = view
        window.orderFrontRegardless()
        for (i, seconds) in [10.5, 12.0, 13.5].enumerated() {
            RunLoop.main.run(until: Date().addingTimeInterval(i == 0 ? seconds : 1.5))
            guard let texture = view.texture(from: scene) else { print("no texture"); continue }
            let out = url.deletingPathExtension().appendingPathExtension("\(i).png")
            try? NSBitmapImageRep(cgImage: texture.cgImage()).representation(using: .png, properties: [:])?.write(to: out)
            print("wrote \(out.path)")
        }
    }

    /// Renders the scene once through SKRenderer, the same path the live overlay uses,
    /// at 2x like a Retina screen, so its scaling and transparency can be checked.
    static func writeMetalFrame(scene: SKScene, size: CGSize, to url: URL) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
        let w = Int(size.width * 2), h = Int(size.height * 2)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc), let commands = queue.makeCommandBuffer() else { return }
        let mode = scene.scaleMode
        scene.scaleMode = .fill
        defer { scene.scaleMode = mode }
        let renderer = SKRenderer(device: device)
        renderer.scene = scene
        renderer.ignoresSiblingOrder = true
        renderer.update(atTime: 1000)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        renderer.render(withViewport: CGRect(x: 0, y: 0, width: w, height: h), commandBuffer: commands, renderPassDescriptor: pass)
        commands.commit()
        commands.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue),
              let image = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path)")
    }
}
