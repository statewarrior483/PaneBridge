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
    private let inputQueue = DispatchQueue(label: "panebridge.input", qos: .userInteractive)

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
            let server = StreamServer(page: page, width: o.pixelWidth, height: o.pixelHeight)
            let capturer = DisplayCapturer(displayID: id, pixelWidth: o.pixelWidth, pixelHeight: o.pixelHeight,
                                           fps: o.fps, encoder: encoder)
            let injector = o.input ? InputInjector(displayID: id) : nil
            let inputQueue = self.inputQueue

            encoder.onCodec = { [weak server] in server?.setCodec($0) }
            encoder.onFrame = { [weak server] in server?.broadcast(frame: $0, isKey: $1, timestamp: $2) }
            server.onKeyframeRequest = { [weak capturer] in capturer?.requestKeyframe() }
            server.onInput = { msg in inputQueue.async { injector?.handle(msg) } }
            server.onViewerCountChanged = { [weak self] in self?.onViewerCountChanged?($0) }
            capturer.onStop = { [weak self] in self?.onStopped?($0) }

            self.encoder = encoder
            self.server = server
            self.capturer = capturer
            self.injector = injector

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
        capturer?.stop()
        server?.stop()
        capturer = nil
        server = nil
        encoder = nil
        injector = nil
        virtualDisplay = nil
    }
}
