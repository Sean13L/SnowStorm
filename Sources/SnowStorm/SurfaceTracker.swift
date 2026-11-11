import AppKit
import ApplicationServices

/// Something on screen that snow can land on or that hides snow behind it.
struct Surface: Equatable {
    let id: String
    let kind: SurfaceKind
    /// Global Cocoa coordinates (origin bottom-left of the primary screen).
    var rect: CGRect
    /// Stacking order: lower values are closer to the viewer.
    var order: Int
}

/// Screen geometry captured on the main thread so background polls can use it.
struct ScreenGeometry: Sendable {
    let frames: [CGRect]
    let visibleFrames: [CGRect]
    var primaryHeight: CGFloat { frames.first?.height ?? 0 }

    @MainActor static func current() -> ScreenGeometry {
        ScreenGeometry(frames: NSScreen.screens.map(\.frame), visibleFrames: NSScreen.screens.map(\.visibleFrame))
    }
    /// Converts a top-left-origin rect (CoreGraphics / AX) into Cocoa coordinates.
    func cocoaRect(fromTopLeft r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}

/// Polls the window server (cheap, no permission) and the Accessibility API
/// (Dock + desktop icons, needs permission) and publishes a list of surfaces.
///
/// The polling itself runs on background queues. The overlays render on the main
/// thread, so a slow window-list or AX call there would freeze snow on every screen
/// at once.
@MainActor
final class SurfaceTracker {
    var onUpdate: (([Surface]) -> Void)?
    private(set) var surfaces: [Surface] = []

    private var windowSurfaces: [Surface] = []
    private var axSurfaces: [Surface] = []
    private var timers: [Timer] = []
    private let myPID = ProcessInfo.processInfo.processIdentifier
    private let windowQueue = DispatchQueue(label: "SnowStorm.windows", qos: .userInitiated)
    private let axQueue = DispatchQueue(label: "SnowStorm.accessibility", qos: .utility)
    private var windowPollBusy = false
    private var axPollBusy = false

    nonisolated private static let ignoredOwners: Set<String> = [
        "Window Server", "Dock", "Wallpaper", "SystemUIServer", "Control Center",
        "Control Centre", "Spotlight", "screencaptureui", "loginwindow", "Screenshot",
    ]
    /// Desktop widgets live in transparent grid cells (180-pt steps) packed edge to edge;
    /// the visible card sits inside with an equal margin on every side. The grid starts
    /// 8 pt from the screen edge and 8 pt under the menu bar, so the card is the cell
    /// inset by 8, which gives the system's even 16-pt spacing between widgets.
    nonisolated static let widgetCardInset: CGFloat = 8

    nonisolated private static let widgetOwners: Set<String> = [
        "NotificationCenter", "Notification Center", "Notification Centre", "Widgets", "chronod",
    ]

    func start() {
        pollAccessibility()
        pollWindows()
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollWindows() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollAccessibility() }
        })
        // Timers keep firing even when the tracker is a little late; a small tolerance
        // lets macOS coalesce wakeups with the display refresh.
        timers.forEach { $0.tolerance = 0.03 }
    }

    /// Re-sends the current surfaces even if nothing moved (e.g. after a settings change).
    func republish() { publish(force: true) }

    // MARK: Windows and widgets

    private func pollWindows() {
        guard !windowPollBusy else { return }   // skip a tick rather than queue up work
        windowPollBusy = true
        let geometry = ScreenGeometry.current()
        let pid = myPID
        windowQueue.async { [weak self] in
            let result = Self.readWindows(geometry: geometry, myPID: pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.windowPollBusy = false
                    self.windowSurfaces = result
                    self.publish(force: false)
                }
            }
        }
    }

    nonisolated private static func readWindows(geometry: ScreenGeometry, myPID: Int32) -> [Surface] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let screens = geometry.frames
        var result: [Surface] = []
        var index = 0
        for w in info {
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != myPID else { continue }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            // Cheapest checks first: most entries are menu extras, shadows and overlays.
            guard layer <= 0 else { continue }
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0.1, !ignoredOwners.contains(owner),
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  bounds.width >= 60, bounds.height >= 40 else { continue }

            let kind: SurfaceKind
            if layer == 0 {
                kind = .window
            } else if widgetOwners.contains(owner) {
                kind = .widget
            } else {
                continue
            }
            var rect = geometry.cocoaRect(fromTopLeft: bounds)
            // A widget host that covers a whole screen isn't a single widget; skip it.
            if kind == .widget, screens.contains(where: { rect.width >= $0.width * 0.9 && rect.height >= $0.height * 0.9 }) { continue }
            // Snow belongs on the visible card, not the cell's invisible margin, and the
            // margin mustn't hide snow on the widget below.
            if kind == .widget { rect = rect.insetBy(dx: widgetCardInset, dy: widgetCardInset) }

            index += 1
            let number = w[kCGWindowNumber as String] as? Int ?? index
            result.append(Surface(id: "w\(number)", kind: kind, rect: rect,
                                  order: kind == .window ? index : 10_000 + index))
        }
        return result
    }

    // MARK: Accessibility (Dock and desktop icons)

    private func pollAccessibility() {
        guard !axPollBusy else { return }
        axPollBusy = true
        let geometry = ScreenGeometry.current()
        axQueue.async { [weak self] in
            var result: [Surface] = []
            if let dock = Self.dockRect(geometry: geometry) {
                result.append(Surface(id: "dock", kind: .dock, rect: dock, order: -1000))
            }
            if AXIsProcessTrusted() {
                for (i, icon) in Self.desktopIcons(geometry: geometry).enumerated() {
                    result.append(Surface(id: icon.id, kind: .desktopIcon, rect: icon.rect, order: 20_000 + i))
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.axPollBusy = false
                    self.axSurfaces = result
                    self.publish(force: false)
                }
            }
        }
    }

    nonisolated private static func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }
    nonisolated private static func children(_ el: AXUIElement) -> [AXUIElement] {
        attribute(el, "AXChildren") as? [AXUIElement] ?? []
    }
    nonisolated private static func role(_ el: AXUIElement) -> String? {
        attribute(el, "AXRole") as? String
    }
    nonisolated private static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = attribute(el, "AXPosition"), let s = attribute(el, "AXSize"),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    nonisolated static func dockRect(geometry: ScreenGeometry) -> CGRect? {
        if AXIsProcessTrusted(),
           let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
            let app = AXUIElementCreateApplication(dock.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 0.3)
            for child in children(app) where role(child) == "AXList" {
                if let f = frame(child), f.width > 20, f.height > 20 {
                    let r = geometry.cocoaRect(fromTopLeft: f)
                    if geometry.frames.contains(where: { $0.intersects(r) }) { return r }
                }
            }
        }
        // Without permission, infer the Dock from the space it reserves on screen.
        // The exact width isn't knowable this way, so assume a centered strip.
        for (f, v) in zip(geometry.frames, geometry.visibleFrames) {
            let bottom = v.minY - f.minY, left = v.minX - f.minX, right = f.maxX - v.maxX
            if bottom > 4 { return CGRect(x: f.minX + f.width * 0.25, y: f.minY, width: f.width * 0.5, height: bottom) }
            if left > 4 { return CGRect(x: f.minX, y: f.minY + f.height * 0.25, width: left, height: f.height * 0.5) }
            if right > 4 { return CGRect(x: f.maxX - right, y: f.minY + f.height * 0.25, width: right, height: f.height * 0.5) }
        }
        return nil
    }

    nonisolated static func desktopIcons(geometry: ScreenGeometry) -> [(id: String, rect: CGRect)] {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return [] }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var out: [(String, CGRect)] = []
        // The desktop is a scroll area that hangs directly off Finder's app element
        // (Finder windows sit under AXWindow, so they're not picked up here).
        for area in children(app) where role(area) == "AXScrollArea" {
            collectIcons(area, depth: 0, geometry: geometry, into: &out)
        }
        return out
    }

    nonisolated private static func collectIcons(_ el: AXUIElement, depth: Int, geometry: ScreenGeometry, into out: inout [(String, CGRect)]) {
        guard depth < 3 else { return }
        for child in children(el) {
            let r = role(child)
            if r == "AXImage" || r == "AXButton" {
                guard let f = frame(child), (16...320).contains(f.width), (16...320).contains(f.height) else { continue }
                let title = attribute(child, "AXTitle") as? String ?? attribute(child, "AXDescription") as? String
                let id = "icon:" + (title ?? "\(Int(f.minX)),\(Int(f.minY))")
                out.append((id, geometry.cocoaRect(fromTopLeft: f)))
            } else if r == "AXGroup" || r == "AXList" {
                collectIcons(child, depth: depth + 1, geometry: geometry, into: &out)
            }
        }
    }

    // MARK: Publishing

    private func publish(force: Bool) {
        var all = axSurfaces + windowSurfaces
        for (i, screen) in NSScreen.screens.enumerated() {
            let h = screen.frame.maxY - screen.visibleFrame.maxY
            if h > 2 {
                all.append(Surface(id: "menubar\(i)", kind: .menuBar,
                                   rect: CGRect(x: screen.frame.minX, y: screen.visibleFrame.maxY, width: screen.frame.width, height: h),
                                   order: -2000))
            }
        }
        guard force || all != surfaces else { return }
        surfaces = all
        onUpdate?(all)
    }
}
