import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

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
        config.queueDepth = 5

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        print("Capturing virtual display at \(pixelWidth)x\(pixelHeight) @ \(fps) fps")
    }

    /// Forces a keyframe and, if the screen is idle, re-sends the last frame so a
    /// newly connected client gets a picture immediately.
    func requestKeyframe() {
        encoder.requestKeyframe()
        queue.async { [self] in
            if let lastFrame { encoder.encode(lastFrame) }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let info = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixelBuffer = sb.imageBuffer
        else { return }
        lastFrame = pixelBuffer
        encoder.encode(pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Capture stopped: \(error.localizedDescription)")
        exit(1)
    }
}
