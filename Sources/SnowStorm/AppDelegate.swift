import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var overlays: [OverlayController] = []
    private let tracker = SurfaceTracker()
    private let settings = Settings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one copy at a time.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = Art.menuBarIcon()
            button.toolTip = "SnowStorm"
            button.setAccessibilityLabel("SnowStorm")
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        tracker.onUpdate = { [weak self] surfaces in
            self?.overlays.forEach { $0.scene.apply(surfaces: surfaces) }
        }
        rebuildOverlays()
        tracker.start()

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildOverlays() }
        }
        nc.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.overlays.forEach { $0.scene.settingsChanged() }
                self?.tracker.republish()
            }
        }
        promptForAccessibilityOnce()
    }

    private func rebuildOverlays() {
        overlays.forEach { $0.tearDown() }
        overlays = NSScreen.screens.map { OverlayController(screen: $0) }
        tracker.republish()
    }

    private func promptForAccessibilityOnce() {
        let key = "didPromptForAccessibility"
        guard !AXIsProcessTrusted(), !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(item("Snowing", #selector(toggleSnowing), on: settings.snowing))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "Intensity"))
        for (i, level) in Intensity.allCases.enumerated() {
            let it = item(level.title, #selector(setIntensity(_:)), on: settings.intensity == level)
            it.tag = i
            menu.addItem(it)
        }
        menu.addItem(.separator())
        menu.addItem(item("Snowman", #selector(toggleSnowman), on: settings.snowman))
        let balls = item("Snowballs from the Snowman", #selector(toggleSnowballs), on: settings.snowballs)
        balls.isEnabled = settings.snowman
        menu.addItem(balls)
        menu.addItem(item("Icicles", #selector(toggleIcicles), on: settings.icicles))

        let lands = NSMenuItem(title: "Snow Lands On", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let trusted = AXIsProcessTrusted()
        for (i, kind) in SurfaceKind.allCases.enumerated() {
            var title = kind.title
            if kind == .desktopIcon, !trusted { title += " (needs Accessibility)" }
            let it = item(title, #selector(toggleSurface(_:)), on: settings.surfaceEnabled(kind))
            it.tag = i
            sub.addItem(it)
        }
        lands.submenu = sub
        menu.addItem(lands)
        menu.addItem(item("Shake Off All Snow", #selector(shakeOff)))
        menu.addItem(.separator())

        let login = item("Start at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        login.isEnabled = Bundle.main.bundleURL.pathExtension == "app"
        menu.addItem(login)
        if !trusted {
            menu.addItem(item("Allow Accessibility Access…", #selector(openAccessibility)))
        }
        menu.addItem(.separator())
        menu.addItem(item("About SnowStorm", #selector(showAbout)))
        menu.addItem(item("Quit SnowStorm", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, on: Bool? = nil, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        if let on { it.state = on ? .on : .off }
        return it
    }

    @objc private func toggleSnowing() { settings.snowing.toggle() }
    @objc private func setIntensity(_ sender: NSMenuItem) { settings.intensity = Intensity.allCases[sender.tag] }
    @objc private func toggleSnowman() { settings.snowman.toggle() }
    @objc private func toggleSnowballs() { settings.snowballs.toggle() }
    @objc private func toggleIcicles() { settings.icicles.toggle() }
    @objc private func toggleSurface(_ sender: NSMenuItem) {
        let kind = SurfaceKind.allCases[sender.tag]
        settings.setSurface(kind, enabled: !settings.surfaceEnabled(kind))
    }
    @objc private func shakeOff() { overlays.forEach { $0.scene.shakeOffAllSnow() } }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSApp.activate()
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't change Start at Login"
            alert.runModal()
        }
    }

    @objc private func openAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showAbout() {
        NSApp.activate()
        let credits = NSAttributedString(
            string: "Snow for your desktop. It settles on windows, icons, widgets, the menu bar and the Dock.\n\n"
                + "SnowStorm only reads where windows, icons and the Dock are. It never reads their contents, "
                + "collects no data and never connects to the internet.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "SnowStorm", .credits: credits])
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
