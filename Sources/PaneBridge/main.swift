import Foundation
import CoreGraphics
import ApplicationServices
import AppKit
import VirtualDisplayKit

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: Options

struct Options {
    var width = 1920
    var height = 1080
    var fps = 60
    var bitrateMbps = 20.0
    var hiDPI = false
    var port: UInt16 = 8080
    var input = true
    var position = "right"

    var pixelWidth: Int { hiDPI ? width * 2 : width }
    var pixelHeight: Int { hiDPI ? height * 2 : height }

    static let usage = """
    PaneBridge - use another computer's browser as an extra Mac display

    Usage: PaneBridge [options]
      --width N        display width in points      (default 1920)
      --height N       display height in points     (default 1080)
      --fps N          frame rate                   (default 60)
      --bitrate N      video bitrate in Mbps        (default 20)
      --hidpi          Retina mode (renders at 2x; needs a high-res viewer screen)
      --position P     right|left|above|below main display (default right)
      --port N         HTTP port; WebSocket uses N+1 (default 8080)
      --no-input       ignore mouse/keyboard from the viewer
    """

    static func parse() -> Options {
        var o = Options()
        // Settings picked from the menu bar (command-line flags still win).
        let d = UserDefaults.standard
        if d.integer(forKey: "width") > 0 { o.width = d.integer(forKey: "width") }
        if d.integer(forKey: "height") > 0 { o.height = d.integer(forKey: "height") }
        o.hiDPI = d.bool(forKey: "hidpi")
        var args = CommandLine.arguments.dropFirst().makeIterator()
        func next(_ flag: String) -> String {
            guard let v = args.next() else { fail("\(flag) needs a value") }
            return v
        }
        while let a = args.next() {
            switch a {
            case "--width": o.width = Int(next(a)) ?? o.width
            case "--height": o.height = Int(next(a)) ?? o.height
            case "--fps": o.fps = Int(next(a)) ?? o.fps
            case "--bitrate": o.bitrateMbps = Double(next(a)) ?? o.bitrateMbps
            case "--hidpi": o.hiDPI = true
            case "--position": o.position = next(a)
            case "--port": o.port = UInt16(next(a)) ?? o.port
            case "--no-input": o.input = false
            case "-h", "--help": print(usage); exit(0)
            case let a where a.hasPrefix("-psn_"): break  // added by Finder on some macOS versions
            default: fail("Unknown option \(a)\n\n\(usage)")
            }
        }
        return o
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    if runningAsApp {
        if Thread.isMainThread { showAlertAndExit("PaneBridge couldn't start", message) }
        DispatchQueue.main.sync { showAlertAndExit("PaneBridge couldn't start", message) }
    }
    exit(1)
}

func lanAddresses() -> [String] {
    var result: [String] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
    defer { freeifaddrs(ifaddr) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(ptr.pointee.ifa_flags)
        guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
              flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            let ip = String(cString: host)
            if !ip.hasPrefix("169.254.") { result.append(ip) }
        }
    }
    return result
}

/// Puts the virtual display next to the main display so the mouse can cross over.
func arrange(_ id: CGDirectDisplayID, _ o: Options) {
    let main = CGDisplayBounds(CGMainDisplayID())
    let w = CGFloat(o.width), h = CGFloat(o.height)
    let origin: CGPoint
    switch o.position {
    case "left": origin = CGPoint(x: main.minX - w, y: main.minY)
    case "above": origin = CGPoint(x: main.minX, y: main.minY - h)
    case "below": origin = CGPoint(x: main.minX, y: main.maxY)
    default: origin = CGPoint(x: main.maxX, y: main.minY)
    }
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else { return }
    CGConfigureDisplayOrigin(config, id, Int32(origin.x), Int32(origin.y))
    CGCompleteDisplayConfiguration(config, .forSession)
}

// MARK: Startup

let options = Options.parse()

if !CGPreflightScreenCaptureAccess() {
    CGRequestScreenCaptureAccess()
    print("""
    ⚠️  PaneBridge needs Screen Recording permission.
       System Settings → Privacy & Security → Screen & System Audio Recording → enable your
       terminal app (or PaneBridge.app), then quit and reopen it.
    """)
}
if options.input && !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) {
    print("""
    ⚠️  Mouse/keyboard from the viewer needs Accessibility permission.
       System Settings → Privacy & Security → Accessibility → enable your terminal app.
       (Streaming works without it.)
    """)
}

// Inside PaneBridge.app the page is in Contents/Resources; for `swift run` it's in the SwiftPM bundle.
guard let pageURL = Bundle.main.url(forResource: "client", withExtension: "html")
        ?? Bundle.module.url(forResource: "client", withExtension: "html"),
      let page = try? Data(contentsOf: pageURL) else { fail("viewer page missing from bundle") }

guard let virtualDisplay = PBVirtualDisplay(name: "PaneBridge Display", width: UInt32(options.width),
                                            height: UInt32(options.height), refreshRate: Double(options.fps),
                                            hiDPI: options.hiDPI) else {
    fail("Could not create the virtual display. Is PaneBridge already running (in Terminal or the menu bar)? Quit it and try again.")
}
let displayID = virtualDisplay.displayID
print("Created virtual display #\(displayID): \(options.width)x\(options.height)\(options.hiDPI ? " (Retina)" : "")")
DispatchQueue.main.asyncAfter(deadline: .now() + 1) { arrange(displayID, options) }

let encoder: H264Encoder
do {
    encoder = try H264Encoder(width: options.pixelWidth, height: options.pixelHeight, fps: options.fps,
                              bitrate: Int(options.bitrateMbps * 1_000_000))
} catch { fail(error.localizedDescription) }

let server = StreamServer(page: page, width: options.pixelWidth, height: options.pixelHeight)
let capturer = DisplayCapturer(displayID: displayID, pixelWidth: options.pixelWidth,
                               pixelHeight: options.pixelHeight, fps: options.fps, encoder: encoder)
let injector = options.input ? InputInjector(displayID: displayID) : nil
let inputQueue = DispatchQueue(label: "panebridge.input", qos: .userInteractive)

encoder.onCodec = { server.setCodec($0) }
encoder.onFrame = { server.broadcast(frame: $0, isKey: $1, timestamp: $2) }
server.onKeyframeRequest = { capturer.requestKeyframe() }
server.onInput = { msg in inputQueue.async { injector?.handle(msg) } }

do { try server.start(port: options.port) } catch { fail("could not start server: \(error)") }

Task {
    do {
        try await capturer.start()
    } catch {
        fail("""
        \(error.localizedDescription)

        If this is a permissions error: open System Settings → Privacy & Security → \
        Screen & System Audio Recording, turn on \(runningAsApp ? "PaneBridge" : "your terminal app"), then open it again.
        """)
    }
    print("\nOn your Windows PC, open Chrome or Edge and go to:")
    for (url, label) in viewerURLs(port: options.port) { print("   \(url)   \(label)") }
    print("\n(Both computers must be on the same network. Press Ctrl+C here to stop.)\n")
}

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    print("\nStopping, removing virtual display.")
    exit(0)
}
sigint.resume()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu-bar only, no Dock icon
let menuBar = MenuBarController(options: options)
withExtendedLifetime((virtualDisplay, menuBar)) {
    app.run()
}
