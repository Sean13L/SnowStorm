import AppKit
import ApplicationServices

/// `open SnowStorm.app --args --dump-widgets out.txt`: writes the widget windows and
/// Notification Centre's accessibility tree, to calibrate where widget cards sit.
@MainActor
enum Diagnostics {
    static func dumpWidgets(to url: URL) {
        var out = "trusted: \(AXIsProcessTrusted())\n"
        if let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
            for w in info where (w[kCGWindowLayer as String] as? Int ?? 0) < 0 {
                out += "window \(w[kCGWindowOwnerName as String] ?? "?") \(w[kCGWindowBounds as String] ?? "")\n"
            }
        }
        func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
        }
        func frame(_ e: AXUIElement) -> String {
            guard let p = attr(e, "AXPosition"), let s = attr(e, "AXSize") else { return "" }
            var pt = CGPoint.zero, sz = CGSize.zero
            AXValueGetValue(p as! AXValue, .cgPoint, &pt)
            AXValueGetValue(s as! AXValue, .cgSize, &sz)
            return "\(CGRect(origin: pt, size: sz))"
        }
        func dump(_ e: AXUIElement, _ depth: Int) {
            guard depth < 8 else { return }
            let role = attr(e, "AXRole") as? String ?? "?"
            let sub = attr(e, "AXSubrole") as? String ?? ""
            let desc = String((attr(e, "AXDescription") as? String ?? attr(e, "AXTitle") as? String ?? "").prefix(30))
            out += String(repeating: "  ", count: depth) + "\(role) \(sub) \(desc) \(frame(e))\n"
            for c in attr(e, "AXChildren") as? [AXUIElement] ?? [] { dump(c, depth + 1) }
        }
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == "com.apple.notificationcenterui" {
            let el = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(el, 1)
            dump(el, 0)
        }
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }
}
