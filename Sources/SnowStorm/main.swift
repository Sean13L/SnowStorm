import AppKit

MainActor.assumeIsolated {
    // `SnowStorm --render-icon out.png` draws the app icon (used by build.sh) and exits.
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
        do {
            try Art.renderAppIcon(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        } catch {
            FileHandle.standardError.write("Icon render failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    if let i = args.firstIndex(of: "--dump-widgets"), i + 1 < args.count {
        Diagnostics.dumpWidgets(to: URL(fileURLWithPath: args[i + 1]))
        exit(0)
    }
    if let i = args.firstIndex(of: "--preview"), i + 1 < args.count {
        Preview.render(to: URL(fileURLWithPath: args[i + 1]))
        exit(0)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
    app.run()
}
