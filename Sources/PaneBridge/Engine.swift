import Foundation
import CoreGraphics
import VirtualDisplayKit

/// Owns the whole pipeline: virtual display -> capture -> encoder -> server, plus input.
final class Engine {
    let options: Options
    var onViewerCountChanged: ((Int) -> Void)?
    /// Called if capture stops unexpectedly after a successful start.
    var onStopped: ((String) -> Void)?

    private var virtualDisplay: PBVirtualDisplay?
    private var encoder: H264Encoder?
    private var server: StreamServer?
    private var capturer: DisplayCapturer?
    private var injector: InputInjector?
    private var rtc: RTCStreamer?
    private var cursorWatcher: CursorWatcher?
    private let inputQueue = DispatchQueue(label: "panebridge.input", qos: .userInteractive)
    /// Keeps macOS from App-Napping a menu-bar app with no visible windows, which
    /// throttles its timers and threads and shows up as stutter.
    private var activity: NSObjectProtocol?

    init(options: Options) {
        self.options = options
    }

    func start() async throws {
        let o = options
        let page = try loadViewerPage()

        guard let display = PBVirtualDisplay(name: "PaneBridge Display", width: UInt32(o.width), height: UInt32(o.height),
                                             refreshRate: Double(o.fps), hiDPI: o.hiDPI) else {
            throw PaneBridgeError("Couldn't create the virtual display. Is another copy of PaneBridge already running (in Terminal or the menu bar)? Quit it and try again.")
        }
        virtualDisplay = display
        let id = display.displayID
        print("Created virtual display #\(id): \(o.width)x\(o.height)\(o.hiDPI ? " (Retina)" : "")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { arrange(id, o) }

        do {
            let encoder = try H264Encoder(width: o.pixelWidth, height: o.pixelHeight, fps: o.fps,
                                          bitrate: Int(o.bitrateMbps * 1_000_000))
            let server = StreamServer(page: page, width: o.pixelWidth, height: o.pixelHeight,
                                      pointWidth: o.width, pointHeight: o.height, inputEnabled: o.input)
            let rtc = RTCStreamer(width: o.pixelWidth, height: o.pixelHeight, fps: o.fps,
                                  bitrate: Int(o.bitrateMbps * 1_000_000))
            let capturer = DisplayCapturer(displayID: id, pixelWidth: o.pixelWidth, pixelHeight: o.pixelHeight,
                                           fps: o.fps, encoder: encoder)
            let tracker = PointerTracker()
            let injector = o.input ? InputInjector(displayID: id, tracker: tracker) : nil
            let inputQueue = self.inputQueue

            encoder.onCodec = { [weak server] in server?.setCodec($0) }
            encoder.onFrame = { [weak server] in server?.broadcast(frame: $0, isKey: $1, timestamp: $2) }
            server.onKeyframeRequest = { [weak capturer] in capturer?.requestKeyframe() }
            server.onInput = { msg in inputQueue.async { injector?.handle(msg) } }
            server.onViewerCountChanged = { [weak self] in self?.onViewerCountChanged?($0) }
            capturer.onStop = { [weak self] in self?.onStopped?($0) }
            capturer.shouldHoldFrames = { [weak server] in server?.isBackedUp ?? false }
            server.onDrained = { [weak capturer] in capturer?.flushHeldFrame() }
            // WebRTC viewers get raw frames; our own encoder only runs for WebSocket viewers.
            capturer.rawFrameSink = { [weak rtc] in rtc?.push($0, micros: $1) }
            capturer.wantsEncodedFrames = { [weak server] in server?.wantsEncodedFrames ?? false }
            rtc.send = { [weak server] in server?.send(json: $1, to: $0) }
            server.onSignal = { [weak rtc] in rtc?.handle($0, $1) }
            server.onClientGone = { [weak rtc] in rtc?.remove($0) }
            // While a PC controls the Mac it draws its own pointer, so leave it out of the video.
            server.onLocalCursorChanged = { [weak capturer] in capturer?.setShowsCursor(!$0) }
            if o.input {
                let watcher = CursorWatcher(displayID: id, tracker: tracker)
                watcher.onChange = { [weak server] in server?.setCursor(json: $0) }
                watcher.onPointer = { [weak server] in server?.send(json: $0, to: nil) }
                watcher.start()
                cursorWatcher = watcher
            }
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical],
                reason: "Streaming the PaneBridge display")

            self.encoder = encoder
            self.server = server
            self.capturer = capturer
            self.injector = injector
            self.rtc = rtc

            do {
                try server.start(port: o.port)
            } catch {
                throw PaneBridgeError("Couldn't open port \(o.port). Is another copy of PaneBridge already running? (\(error.localizedDescription))")
            }
            do {
                try await capturer.start()
            } catch {
                throw PaneBridgeError("Screen capture failed: \(error.localizedDescription)\n\nMake sure Screen Recording is allowed for PaneBridge, then relaunch it.")
            }
        } catch {
            stop()
            throw error
        }
    }

    /// Tears everything down; the virtual display disappears when released.
    func stop() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        cursorWatcher?.stop()
        cursorWatcher = nil
        capturer?.stop()
        server?.stop()
        rtc?.stop()
        rtc = nil
        capturer = nil
        server = nil
        encoder = nil
        injector = nil
        virtualDisplay = nil
    }
}
