import AppKit

/// True when launched as PaneBridge.app (double-clicked) rather than from Terminal.
let runningAsApp = Bundle.main.bundlePath.hasSuffix(".app")

/// Menu-bar icon showing the viewer URLs, a resolution picker and Quit.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let options: Options

    static let presets: [(Int, Int)] = [(1280, 720), (1600, 900), (1920, 1080), (1920, 1200), (2560, 1440), (3440, 1440), (3840, 2160)]

    init(options: Options) {
        self.options = options
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "PaneBridge")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(header("PaneBridge — \(options.width)×\(options.height)\(options.hiDPI ? " Retina" : "")"))
        menu.addItem(.separator())
        menu.addItem(header("On your PC, open (click to copy):"))
        let urls = viewerURLs(port: options.port)
        if urls.isEmpty { menu.addItem(header("   No network connection")) }
        for (url, label) in urls {
            let item = NSMenuItem(title: "\(url)   \(label)", action: #selector(copyURL(_:)), keyEquivalent: "")
            item.representedObject = url
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let res = NSMenuItem(title: "Resolution", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (w, h) in Self.presets {
            let item = NSMenuItem(title: "\(w) × \(h)", action: #selector(pickResolution(_:)), keyEquivalent: "")
            item.representedObject = [w, h]
            item.target = self
            item.state = (w == options.width && h == options.height) ? .on : .off
            sub.addItem(item)
        }
        sub.addItem(.separator())
        let retina = NSMenuItem(title: "Retina (HiDPI)", action: #selector(toggleRetina), keyEquivalent: "")
        retina.target = self
        retina.state = options.hiDPI ? .on : .off
        sub.addItem(retina)
        res.submenu = sub
        menu.addItem(res)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit PaneBridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func copyURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc private func pickResolution(_ sender: NSMenuItem) {
        guard let wh = sender.representedObject as? [Int] else { return }
        UserDefaults.standard.set(wh[0], forKey: "width")
        UserDefaults.standard.set(wh[1], forKey: "height")
        relaunch()
    }

    @objc private func toggleRetina() {
        UserDefaults.standard.set(!options.hiDPI, forKey: "hidpi")
        relaunch()
    }

    private func relaunch() {
        guard runningAsApp else {
            let alert = NSAlert()
            alert.messageText = "Saved. Restart PaneBridge to apply."
            alert.informativeText = "Command-line flags like --width override this setting."
            alert.runModal()
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this instance to exit (and its virtual display to go away) before reopening.
        task.arguments = ["-c", "sleep 1; /usr/bin/open -n \"\(Bundle.main.bundlePath)\""]
        try? task.run()
        exit(0)
    }
}

/// Viewer URLs for every usable network interface, Tailscale first.
func viewerURLs(port: UInt16) -> [(String, String)] {
    lanAddresses()
        .map { ip -> (String, String) in
            let isTailscale = ip.hasPrefix("100.") && (Int(ip.split(separator: ".")[1]) ?? 0) >= 64 && (Int(ip.split(separator: ".")[1]) ?? 0) < 128
            return ("http://\(ip):\(port)", isTailscale ? "(Tailscale)" : "(local network)")
        }
        .sorted { $0.1 == "(Tailscale)" && $1.1 != "(Tailscale)" }
}

func showAlertAndExit(_ title: String, _ message: String) -> Never {
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.runModal()
    exit(1)
}
