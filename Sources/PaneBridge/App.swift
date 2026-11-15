import AppKit
import SwiftUI
import Combine
import ApplicationServices

enum EnginePhase: Equatable {
    case waitingForPermission
    case restarting
    case starting
    case running
    case failed(String)
}

enum AppTab: Hashable { case setup, settings }

let bundleID = Bundle.main.bundleIdentifier ?? "app.panebridge.PaneBridge"

/// Everything the menu bar and setup window show, kept on the main thread.
final class AppState: ObservableObject {
    static let resolutions: [(Int, Int)] = [(1280, 720), (1366, 768), (1600, 900), (1920, 1080), (1920, 1200),
                                            (2560, 1080), (2560, 1440), (3440, 1440), (3840, 2160)]
    static let frameRates = [24, 30, 60, 120]

    @Published private(set) var options: Options
    @Published private(set) var screenRecording = false
    @Published private(set) var accessibility = false
    @Published private(set) var phase: EnginePhase = .waitingForPermission
    @Published private(set) var viewers = 0
    @Published private(set) var urls: [ViewerURL] = []
    @Published private(set) var everConnected: Bool
    @Published var tab: AppTab = .setup
    /// Settings being edited in the Settings tab (applied with Apply).
    @Published var draft: Options
    @Published private(set) var lastCopied: String?
    @Published var showAtLaunch: Bool {
        didSet { UserDefaults.standard.set(showAtLaunch, forKey: "showGuideAtLaunch") }
    }

    var closeWindow: (() -> Void)?
    var primaryURL: String? { urls.first?.url }

    private var engine: Engine?
    private var timer: Timer?

    private let autoStart: Bool

    init(options: Options, autoStart: Bool = true) {
        self.options = options
        self.draft = options
        self.autoStart = autoStart
        let d = UserDefaults.standard
        everConnected = d.bool(forKey: "everConnected")
        showAtLaunch = d.object(forKey: "showGuideAtLaunch") as? Bool ?? true
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    /// Polls permissions and network addresses; starts streaming once allowed.
    func refresh() {
        let sr = CGPreflightScreenCaptureAccess()
        if sr != screenRecording { screenRecording = sr }
        let ax = AXIsProcessTrusted()
        if ax != accessibility { accessibility = ax }
        let u = viewerURLs(port: options.port)
        if u != urls { urls = u }
        if autoStart && screenRecording && phase == .waitingForPermission { startEngine() }
    }

    func startEngine() {
        switch phase {
        case .starting, .running: return
        default: break
        }
        phase = .starting
        let engine = Engine(options: options)
        self.engine = engine
        engine.onViewerCountChanged = { [weak self] n in
            DispatchQueue.main.async { self?.viewersChanged(n) }
        }
        engine.onStopped = { [weak self] message in
            DispatchQueue.main.async {
                guard let self, self.engine === engine else { return }
                engine.stop()
                self.engine = nil
                self.viewers = 0
                self.phase = .failed("Screen capture stopped: \(message)")
            }
        }
        Task {
            var failure: String?
            do { try await engine.start() } catch { failure = error.localizedDescription }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.engine === engine else { return }
                if let failure {
                    self.engine = nil
                    self.phase = .failed(failure)
                } else {
                    self.phase = .running
                }
            }
        }
    }

    /// Stops the stream, waits for macOS to remove the old display, then starts again.
    func restartEngine() {
        engine?.stop()
        engine = nil
        viewers = 0
        phase = .restarting
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.phase = .waitingForPermission
            self.refresh()
        }
    }

    func applyDraft() {
        draft.bitrateMbps = draft.bitrateMbps.rounded()
        draft.save()
        options = draft
        restartEngine()
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        lastCopied = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.lastCopied == text { self?.lastCopied = nil }
        }
    }

    private func viewersChanged(_ n: Int) {
        viewers = n
        if n > 0 && !everConnected {
            everConnected = true
            UserDefaults.standard.set(true, forKey: "everConnected")
            showAtLaunch = false
        }
    }

    // MARK: Permissions

    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        openPrivacySettings("Privacy_ScreenCapture")
    }

    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    /// After an app update macOS can keep a stale entry that looks enabled but isn't.
    func resetScreenRecording() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "ScreenCapture", bundleID]
        try? task.run()
        task.waitUntilExit()
        requestScreenRecording()
    }

    func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    var statusLine: String {
        switch phase {
        case .waitingForPermission: return screenRecording ? "Starting…" : "Needs Screen Recording permission"
        case .restarting, .starting: return "Starting virtual display…"
        case .failed: return "Not running: open Setup for details"
        case .running:
            return viewers == 0 ? "Ready, waiting for your PC" : "Streaming to \(viewers) viewer\(viewers == 1 ? "" : "s")"
        }
    }

    var needsAttention: Bool {
        if case .failed = phase { return true }
        return !screenRecording
    }
}

func relaunchApp() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    // Let this instance exit (and its virtual display disappear) before reopening.
    task.arguments = ["-c", "sleep 1; /usr/bin/open -n \"\(Bundle.main.bundlePath)\""]
    try? task.run()
    exit(0)
}

// MARK: App delegate

func runMenuBarApp(_ options: Options) -> Never {
    let app = NSApplication.shared
    let delegate = AppDelegate(options: options)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)  // lives in the menu bar, no Dock icon
    withExtendedLifetime(delegate) { app.run() }
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state: AppState
    private var menuBar: MenuBarController?
    private var window: NSWindow?

    init(options: Options) {
        state = AppState(options: options)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != getpid() }
        if !others.isEmpty {
            let alert = NSAlert()
            alert.messageText = "PaneBridge is already running"
            alert.informativeText = "Look for the display icon in your menu bar."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            exit(0)
        }

        state.closeWindow = { [weak self] in self?.window?.close() }
        menuBar = MenuBarController(state: state) { [weak self] tab in self?.showWindow(tab) }
        if state.showAtLaunch || !state.screenRecording {
            showWindow(.setup)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func showWindow(_ tab: AppTab) {
        state.tab = tab
        state.draft = state.options
        if window == nil {
            let host = NSHostingController(rootView: MainView(state: state))
            let w = NSWindow(contentViewController: host)
            w.title = "PaneBridge"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: Menu bar

final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let state: AppState
    private let openWindow: (AppTab) -> Void
    private var cancellables = Set<AnyCancellable>()

    init(state: AppState, openWindow: @escaping (AppTab) -> Void) {
        self.state = state
        self.openWindow = openWindow
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        updateIcon()
    }

    private func updateIcon() {
        let symbol = state.needsAttention ? "exclamationmark.triangle" : (state.viewers > 0 ? "display.2" : "display")
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "PaneBridge")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let o = state.options
        menu.addItem(disabled("PaneBridge: \(state.statusLine)"))
        menu.addItem(disabled("\(o.width)×\(o.height)\(o.hiDPI ? " Retina" : "") · \(o.fps) fps · \(Int(o.bitrateMbps)) Mbps"))
        menu.addItem(.separator())
        if state.urls.isEmpty {
            menu.addItem(disabled("No network connection"))
        } else {
            menu.addItem(disabled("Open on your PC (click to copy):"))
            for v in state.urls {
                let item = NSMenuItem(title: "\(v.url)  (\(v.label))", action: #selector(copyURL(_:)), keyEquivalent: "")
                item.representedObject = v.url
                item.target = self
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(action("Setup Guide…", #selector(openSetup), ""))
        menu.addItem(action("Settings…", #selector(openSettings), ","))
        if case .failed = state.phase {
            menu.addItem(action("Try Again", #selector(retry), ""))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit PaneBridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func copyURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc private func openSetup() { openWindow(.setup) }
    @objc private func openSettings() { openWindow(.settings) }
    @objc private func retry() { state.restartEngine() }
}

// MARK: Snapshot (for README screenshots / UI checks)

/// `PANEBRIDGE_SNAPSHOT=/some/dir PaneBridge` renders the window's tabs to PNGs and exits.
func renderSnapshots(to dir: String, options: Options) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let state = AppState(options: options, autoStart: false)
    let window = NSWindow(contentViewController: NSHostingController(rootView: MainView(state: state)))
    window.title = "PaneBridge"
    window.styleMask = [.titled, .closable, .miniaturizable]
    window.setFrameOrigin(NSPoint(x: -5000, y: -5000))  // off-screen; the window server still draws it
    window.orderFrontRegardless()
    for (tab, name) in [(AppTab.setup, "setup"), (AppTab.settings, "settings")] {
        state.tab = tab
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", "\(dir)/\(name).png"]
        try? task.run()
        task.waitUntilExit()
    }
    exit(0)
}
