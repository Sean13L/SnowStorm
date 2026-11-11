import AppKit
import SpriteKit
import Metal
import QuartzCore

/// Draws a SpriteKit scene into a transparent Metal layer, paced by this screen's
/// own display link.
///
/// Why not `SKView`: on a ProMotion (120 Hz, variable refresh) display, `SKView`
/// paced its frames badly from this background overlay app. Measured on a
/// 120 Hz built-in screen it froze for 150–200 ms every ~9 frames, whatever frame
/// rate was asked for, while the same scene on a 75 Hz external screen was smooth.
/// A `CADisplayLink` with an explicit frame-rate range is what ProMotion is built
/// around, so frames arrive on time and the panel can still drop to a low rate at rest.
@MainActor
final class SnowRenderView: NSView {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let renderer: SKRenderer
    private let metalLayer = CAMetalLayer()
    private var link: CADisplayLink?
    private(set) var framesPerSecond = 60
    let scene: SKScene

    init?(frame: NSRect, scene: SKScene) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.scene = scene
        // Without an SKView, `.resizeFill` collapses the scene to 0×0. `.fill` maps
        // the scene's point coordinates onto the pixel-sized drawable instead.
        scene.scaleMode = .fill
        renderer = SKRenderer(device: device)
        renderer.scene = scene
        renderer.ignoresSiblingOrder = true      // draw order comes from zPosition only
        renderer.shouldCullNonVisibleNodes = true
        super.init(frame: frame)

        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = NSColor.clear.cgColor
        metalLayer.allowsNextDrawableTimeout = true   // never block the main thread for long
        metalLayer.maximumDrawableCount = 3
        metalLayer.presentsWithTransaction = false
        layer = metalLayer
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        updateDrawableSize()
        // NSView.displayLink follows whichever screen this view is on.
        let l = displayLink(target: self, selector: #selector(step(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        applyFrameRate()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    func setFramesPerSecond(_ fps: Int) {
        guard fps != framesPerSecond else { return }
        framesPerSecond = fps
        applyFrameRate()
    }

    private func applyFrameRate() {
        let f = Float(framesPerSecond)
        // A fixed range: ProMotion then refreshes at exactly this rate (or a multiple).
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: f, maximum: f, preferred: f)
    }

    func stop() {
        link?.invalidate()
        link = nil
        renderer.scene = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        renderer.update(atTime: link.timestamp)
        let size = metalLayer.drawableSize
        guard size.width > 0, size.height > 0,
              let drawable = metalLayer.nextDrawable(),
              let commands = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        renderer.render(withViewport: CGRect(origin: .zero, size: size), commandBuffer: commands, renderPassDescriptor: pass)
        commands.present(drawable)
        commands.commit()
    }
}
