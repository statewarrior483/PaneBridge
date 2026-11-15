import Foundation
import CoreGraphics

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: Options

struct Options: Equatable {
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

    Settings saved from the app's setup window are used as defaults.
    """

    /// Settings saved by the app's setup window.
    static func saved() -> Options {
        var o = Options()
        let d = UserDefaults.standard
        if d.integer(forKey: "width") > 0 { o.width = d.integer(forKey: "width") }
        if d.integer(forKey: "height") > 0 { o.height = d.integer(forKey: "height") }
        if d.integer(forKey: "fps") > 0 { o.fps = d.integer(forKey: "fps") }
        if d.double(forKey: "bitrate") > 0 { o.bitrateMbps = d.double(forKey: "bitrate") }
        if let p = d.string(forKey: "position") { o.position = p }
        if d.object(forKey: "input") != nil { o.input = d.bool(forKey: "input") }
        o.hiDPI = d.bool(forKey: "hidpi")
        return o
    }

    func save() {
        let d = UserDefaults.standard
        d.set(width, forKey: "width")
        d.set(height, forKey: "height")
        d.set(fps, forKey: "fps")
        d.set(bitrateMbps, forKey: "bitrate")
        d.set(position, forKey: "position")
        d.set(input, forKey: "input")
        d.set(hiDPI, forKey: "hidpi")
    }

    static func parse() -> Options {
        var o = saved()
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
    exit(1)
}

struct PaneBridgeError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: Networking helpers

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
            if !ip.hasPrefix("169.254.") && !result.contains(ip) { result.append(ip) }
        }
    }
    return result
}

struct ViewerURL: Identifiable, Equatable {
    let url: String
    let isTailscale: Bool
    var id: String { url }
    var label: String { isTailscale ? "Tailscale" : "Local network" }
}

/// Viewer URLs for every usable network interface, Tailscale (100.64.0.0/10) first.
func viewerURLs(port: UInt16) -> [ViewerURL] {
    lanAddresses().map { ip in
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        let tailscale = parts.count == 4 && parts[0] == 100 && (64..<128).contains(parts[1])
        return ViewerURL(url: "http://\(ip):\(port)", isTailscale: tailscale)
    }
    .sorted { $0.isTailscale && !$1.isTailscale }
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

func loadViewerPage() throws -> Data {
    // Inside PaneBridge.app the page is in Contents/Resources; for `swift run` it's in the SwiftPM bundle.
    guard let url = Bundle.main.url(forResource: "client", withExtension: "html")
            ?? Bundle.module.url(forResource: "client", withExtension: "html") else {
        throw PaneBridgeError("Viewer page missing from the app bundle")
    }
    return try Data(contentsOf: url)
}

// MARK: Entry point

/// True when launched as PaneBridge.app rather than the bare binary from Terminal.
let runningAsApp = Bundle.main.bundlePath.hasSuffix(".app")

let launchOptions = Options.parse()
if let dir = ProcessInfo.processInfo.environment["PANEBRIDGE_SNAPSHOT"] {
    renderSnapshots(to: dir, options: launchOptions)
} else if runningAsApp {
    runMenuBarApp(launchOptions)
} else {
    runCommandLine(launchOptions)
}
