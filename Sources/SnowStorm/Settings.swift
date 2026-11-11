import Foundation
import CoreGraphics

/// How hard it snows. Rates are tuned for a 1440-pt-wide screen and scaled by width.
enum Intensity: String, CaseIterable {
    case light, normal, blizzard

    var title: String {
        switch self {
        case .light: return "Light"
        case .normal: return "Normal"
        case .blizzard: return "Blizzard"
        }
    }
    /// Each flake is a sprite SpriteKit updates every frame, so these counts are the
    /// main lever on CPU use.
    var spawnRate: Double {
        switch self { case .light: return 9; case .normal: return 27; case .blizzard: return 90 }
    }
    var maxFlakes: Int {
        switch self { case .light: return 105; case .normal: return 300; case .blizzard: return 820 }
    }
    var speed: CGFloat {
        switch self { case .light: return 0.9; case .normal: return 1; case .blizzard: return 1.75 }
    }
    var windStrength: CGFloat {
        switch self { case .light: return 10; case .normal: return 22; case .blizzard: return 95 }
    }
}

/// Every kind of thing snow can land on.
enum SurfaceKind: String, CaseIterable {
    case window, desktopIcon, widget, menuBar, dock, ground

    var title: String {
        switch self {
        case .window: return "Windows"
        case .desktopIcon: return "Desktop Icons"
        case .widget: return "Widgets"
        case .menuBar: return "Menu Bar"
        case .dock: return "Dock"
        case .ground: return "Bottom of Screen"
        }
    }
    /// Tallest a pile can get on this surface, in points.
    var maxPile: CGFloat {
        switch self {
        case .window: return 12
        case .desktopIcon: return 7
        case .widget: return 9
        case .menuBar: return 0
        case .dock: return 24
        case .ground: return 18
        }
    }
    /// Corner radius of the surface, so piles wrap around rounded corners instead of
    /// sticking out square. There's no public API for the real value; these match
    /// the system look (macOS 26+ uses noticeably rounder windows and Dock).
    var cornerRadius: CGFloat {
        let modern = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
        switch self {
        case .window: return modern ? 22 : 10
        case .widget: return modern ? 22 : 16
        case .dock: return modern ? 24 : 12
        case .desktopIcon: return 8
        case .menuBar, .ground: return 0
        }
    }
    /// Chance a near flake crossing the top edge settles instead of drifting past.
    var landingChance: CGFloat {
        switch self {
        case .window: return 0.55
        case .desktopIcon: return 0.8
        case .widget: return 0.6
        case .menuBar: return 0
        case .dock: return 0.9
        case .ground: return 0.85
        }
    }
}

@MainActor
final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("SnowStorm.settingsDidChange")

    private let defaults = UserDefaults.standard

    private init() {
        var initial: [String: Any] = [
            "snowing": true,
            "intensity": Intensity.normal.rawValue,
            "snowman": true,
            "snowballs": true,
            "icicles": true,
        ]
        for kind in SurfaceKind.allCases { initial["surface.\(kind.rawValue)"] = true }
        defaults.register(defaults: initial)
    }

    var snowing: Bool {
        get { defaults.bool(forKey: "snowing") }
        set { defaults.set(newValue, forKey: "snowing"); changed() }
    }
    var intensity: Intensity {
        get { Intensity(rawValue: defaults.string(forKey: "intensity") ?? "") ?? .normal }
        set { defaults.set(newValue.rawValue, forKey: "intensity"); changed() }
    }
    var snowman: Bool {
        get { defaults.bool(forKey: "snowman") }
        set { defaults.set(newValue, forKey: "snowman"); changed() }
    }
    var snowballs: Bool {
        get { defaults.bool(forKey: "snowballs") }
        set { defaults.set(newValue, forKey: "snowballs"); changed() }
    }
    var icicles: Bool {
        get { defaults.bool(forKey: "icicles") }
        set { defaults.set(newValue, forKey: "icicles"); changed() }
    }

    func surfaceEnabled(_ kind: SurfaceKind) -> Bool {
        defaults.bool(forKey: "surface.\(kind.rawValue)")
    }
    func setSurface(_ kind: SurfaceKind, enabled: Bool) {
        defaults.set(enabled, forKey: "surface.\(kind.rawValue)")
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
