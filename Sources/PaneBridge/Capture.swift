import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import QuartzCore

/// Host clock in microseconds (same clock as ScreenCaptureKit timestamps).
func hostMicros() -> Int64 { Int64(CACurrentMediaTime() * 1_000_000) }

/// Captures one display with ScreenCaptureKit and feeds frames to the encoder.
final class DisplayCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private let displayID: CGDirectDisplayID
    private let pixelWidth: Int
    private let pixelHeight: Int
    private let fps: Int
    private let encoder: H264Encoder
    private let queue = DispatchQueue(label: "panebridge.capture", qos: .userInteractive)
    private var stream: SCStream?
    /// ScreenCaptureKit only delivers frames when the screen changes, so keep the
    /// latest one around to answer keyframe requests on a static screen.
    private var lastFrame: CVPixelBuffer?
    var onStop: ((String) -> Void)?
    /// Returns true when the network is backed up; the frame is then held back.
    var shouldHoldFrames: (() -> Bool)?
    /// A newer frame was held back and still needs to be sent once the network drains.
    private var holding = false
    private var stopping = false
    private var config: SCStreamConfiguration?
    /// Every captured frame (with its capture time in host µs) also goes here, for WebRTC viewers.
    var rawFrameSink: ((CVPixelBuffer, Int64) -> Void)?
    /// False when no viewer needs our own H.264 stream (all of them use WebRTC), so skip encoding.
    var wantsEncodedFrames: (() -> Bool)?
    private var lastFrameTime: Int64 = 0
    private var idleTimer: DispatchSourceTimer?

    init(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int, fps: Int, encoder: H264Encoder) {
        self.displayID = displayID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fps = fps
        self.encoder = encoder
    }

    func start() async throws {
        // A freshly created virtual display can take a moment to show up.
        var display: SCDisplay?
        for _ in 0..<50 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            display = content.displays.first { $0.displayID == displayID }
            if display != nil { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard let display else {
            throw NSError(domain: "PaneBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Virtual display \(displayID) not visible to ScreenCaptureKit"])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        // 3 is the smallest depth ScreenCaptureKit runs smoothly with; fewer drops frames.
        config.queueDepth = 3
        self.config = config

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        startIdleTimer()
        print("Capturing virtual display at \(pixelWidth)x\(pixelHeight) @ \(fps) fps")
    }

    /// Forces a keyframe and, if the screen is idle, re-sends the last frame so a
    /// newly connected client gets a picture immediately.
    func requestKeyframe() {
        encoder.requestKeyframe()
        queue.async { [self] in
            if let lastFrame { encoder.encode(lastFrame, captureMicros: hostMicros()) }
        }
    }

    /// Hides the Mac cursor from the video while the PC draws its own (zero-latency) pointer.
    func setShowsCursor(_ show: Bool) {
        queue.async { [self] in
            guard let config, let stream, config.showsCursor != show else { return }
            config.showsCursor = show
            stream.updateConfiguration(config) { error in
                if let error { print("Couldn't update cursor capture: \(error.localizedDescription)") }
            }
        }
    }

    /// ScreenCaptureKit sends nothing while the screen is static. WebRTC viewers that just joined
    /// (or lost a packet) need a fresh frame to get a keyframe, so re-send the last one when idle.
    private func startIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
        timer.setEventHandler { [weak self] in
            guard let self, let sink = rawFrameSink, let lastFrame else { return }
            let now = hostMicros()
            if now - lastFrameTime > 200_000 { sink(lastFrame, now) }
        }
        timer.resume()
        idleTimer = timer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let info = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixelBuffer = sb.imageBuffer
        else { return }
        lastFrame = pixelBuffer
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let captured = pts.isValid ? Int64(pts.seconds * 1_000_000) : hostMicros()
        lastFrameTime = hostMicros()
        rawFrameSink?(pixelBuffer, captured)
        guard wantsEncodedFrames?() ?? true else { holding = false; return }
        if shouldHoldFrames?() == true {
            holding = true   // skip this one; the newest frame is sent when the viewer catches up
            return
        }
        holding = false
        encoder.encode(pixelBuffer, captureMicros: captured)
    }

    /// The viewer caught up: send the newest frame we held back, if any.
    func flushHeldFrame() {
        queue.async { [self] in
            guard holding, let lastFrame else { return }
            holding = false
            encoder.encode(lastFrame, captureMicros: hostMicros())
        }
    }

    func stop() {
        stopping = true
        idleTimer?.cancel()
        idleTimer = nil
        stream?.stopCapture { _ in }
        stream = nil
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !stopping else { return }
        print("Capture stopped: \(error.localizedDescription)")
        onStop?(error.localizedDescription)
    }
}
