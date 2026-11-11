import AppKit
import SpriteKit

/// A tiny window that sits exactly over the snowman so he is the only thing that catches clicks.
final class SnowmanClickView: NSView {
    var circles: [CGRect] = [] { didSet { needsDisplay = true } }
    var onClick: ((NSPoint) -> Void)?

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // The window server only routes clicks to pixels that aren't fully transparent.
        // A near-invisible fill over the (white) snowballs makes them clickable.
        NSColor(white: 1, alpha: 0.02).setFill()
        for c in circles { NSBezierPath(ovalIn: c).fill() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return circles.contains { c in
            hypot(p.x - c.midX, p.y - c.midY) <= c.width / 2 + 4
        } ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?(event.locationInWindow) }
}

/// One transparent, click-through overlay per screen.
@MainActor
final class OverlayController {
    let screen: NSScreen
    let scene: SnowScene
    private let window: NSWindow
    /// The Metal renderer by default; `SNOW_SKVIEW=1` falls back to SKView for comparison.
    private var renderView: SnowRenderView?
    private var skView: SKView?
    private let clickPanel: NSPanel
    private let clickView = SnowmanClickView()

    private static let overlayLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
    private static let behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

    init(screen: NSScreen) {
        self.screen = screen
        let frame = screen.frame

        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = Self.overlayLevel
        window.collectionBehavior = Self.behavior
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.setFrame(frame, display: false)

        scene = SnowScene(screenFrame: frame)
        scene.displayMaxFPS = max(30, screen.maximumFramesPerSecond)
        if let i = CommandLine.arguments.firstIndex(of: "--frame-log"), i + 1 < CommandLine.arguments.count {
            scene.frameLog = []
            scene.frameLogPath = CommandLine.arguments[i + 1] + ".\(screen.localizedName.replacingOccurrences(of: " ", with: "_"))-\(screen.maximumFramesPerSecond)hz.txt"
        }
        let bounds = NSRect(origin: .zero, size: frame.size)
        if ProcessInfo.processInfo.environment["SNOW_SKVIEW"] == nil, let view = SnowRenderView(frame: bounds, scene: scene) {
            renderView = view
            window.contentView = view
        } else {
            let view = SKView(frame: bounds)
            view.allowsTransparency = true
            view.ignoresSiblingOrder = true   // draw order comes from zPosition only
            view.preferredFramesPerSecond = 60
            view.autoresizingMask = [.width, .height]
            window.contentView = view
            view.presentScene(scene)
            skView = view
        }
        window.orderFrontRegardless()

        clickPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        clickPanel.isOpaque = false
        clickPanel.backgroundColor = .clear
        clickPanel.hasShadow = false
        clickPanel.level = NSWindow.Level(rawValue: Self.overlayLevel.rawValue + 1)
        clickPanel.collectionBehavior = Self.behavior
        clickPanel.hidesOnDeactivate = false
        clickPanel.becomesKeyOnlyIfNeeded = true
        clickPanel.isReleasedWhenClosed = false
        clickPanel.animationBehavior = .none
        clickPanel.contentView = clickView

        clickView.onClick = { [weak self] p in self?.handleClick(windowPoint: p) }
        // Rest when nothing is moving: drop to a few frames per second.
        scene.onFrameRateChange = { [weak self] fps in
            self?.renderView?.setFramesPerSecond(fps)
            self?.skView?.preferredFramesPerSecond = fps
        }
        scene.onSnowmanAreaChange = { [weak self] areas in self?.updateClickArea(areas) }
    }

    func tearDown() {
        clickPanel.orderOut(nil)
        window.orderOut(nil)
        renderView?.stop()
        skView?.presentScene(nil)
    }

    private func updateClickArea(_ areas: [CGRect]) {
        guard let first = areas.first else {
            clickPanel.orderOut(nil)
            return
        }
        let union = areas.reduce(first) { $0.union($1) }.insetBy(dx: -6, dy: -6)
        clickPanel.setFrame(union.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY), display: false)
        clickView.frame = NSRect(origin: .zero, size: union.size)
        clickView.circles = areas.map { $0.offsetBy(dx: -union.minX, dy: -union.minY) }
        if !clickPanel.isVisible { clickPanel.orderFrontRegardless() }
    }

    private func handleClick(windowPoint p: NSPoint) {
        let origin = clickPanel.frame.origin
        scene.handleSnowmanClick(at: CGPoint(x: p.x + origin.x - screen.frame.minX, y: p.y + origin.y - screen.frame.minY))
    }
}
