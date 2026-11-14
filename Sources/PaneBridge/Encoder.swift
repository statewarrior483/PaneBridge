import Foundation
import VideoToolbox
import CoreMedia
import QuartzCore

/// Hardware H.264 encoder tuned for low latency. Emits Annex-B frames
/// (start-code delimited, SPS/PPS inlined on keyframes) which browsers'
/// WebCodecs VideoDecoder accepts directly.
final class H264Encoder {
    /// (annexB bytes, isKeyframe, timestamp in microseconds)
    var onFrame: ((Data, Bool, Int64) -> Void)?
    /// WebCodecs codec string, e.g. "avc1.640C28". Called when it changes.
    var onCodec: ((String) -> Void)?

    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var forceKeyframe = true
    private var codecString: String?

    init(width: Int, height: Int, fps: Int, bitrate: Int) throws {
        session = try Self.makeSession(width: width, height: height, lowLatency: true)
            ?? Self.makeSession(width: width, height: height, lowLatency: false)
        guard let session else { throw NSError(domain: "PaneBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create H.264 encoder"]) }

        func set(_ key: CFString, _ value: CFTypeRef) {
            let status = VTSessionSetProperty(session, key: key, value: value)
            if status != noErr { print("  (encoder property \(key) not supported: \(status))") }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (fps * 4) as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 4 as CFNumber)
        // Cap bursts at 2x the average over one second.
        set(kVTCompressionPropertyKey_DataRateLimits, [bitrate * 2 / 8, 1] as CFArray)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    private static func makeSession(width: Int, height: Int, lowLatency: Bool) throws -> VTCompressionSession? {
        var spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
        ]
        if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { return nil }
        let profile = lowLatency ? kVTProfileLevel_H264_ConstrainedHigh_AutoLevel : kVTProfileLevel_H264_High_AutoLevel
        if VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile) != noErr {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        }
        print("Encoder: hardware H.264\(lowLatency ? " (low-latency mode)" : "")")
        return session
    }

    func requestKeyframe() {
        lock.lock(); forceKeyframe = true; lock.unlock()
    }

    /// Call from one serial queue only.
    func encode(_ pixelBuffer: CVPixelBuffer) {
        guard let session else { return }
        lock.lock(); let key = forceKeyframe; forceKeyframe = false; lock.unlock()

        let micros = Int64(CACurrentMediaTime() * 1_000_000)
        let pts = CMTime(value: micros, timescale: 1_000_000)
        let props = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil

        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: props, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            self?.handle(sampleBuffer, micros: micros)
        }
    }

    private static let startCode: [UInt8] = [0, 0, 0, 1]

    private func handle(_ sb: CMSampleBuffer, micros: Int64) {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
        let isKey = !notSync

        var out = Data()
        if isKey, let format = CMSampleBufferGetFormatDescription(sb) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                   parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                   nalUnitHeaderLengthOut: nil)
                guard let ptr, size > 3 else { continue }
                out.append(contentsOf: Self.startCode)
                out.append(ptr, count: size)
                if i == 0 { // SPS -> profile/constraints/level for the codec string
                    let codec = String(format: "avc1.%02X%02X%02X", ptr[1], ptr[2], ptr[3])
                    if codec != codecString { codecString = codec; onCodec?(codec) }
                }
            }
        }

        // Convert AVCC (4-byte big-endian length prefixes) to Annex-B start codes.
        let total = CMBlockBufferGetDataLength(block)
        var avcc = Data(count: total)
        let copied = avcc.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: raw.baseAddress!)
        }
        guard copied == noErr else { return }
        avcc.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var offset = 0
            while offset + 4 <= total {
                let len = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
                offset += 4
                guard len > 0, offset + len <= total else { break }
                out.append(contentsOf: Self.startCode)
                out.append(UnsafeBufferPointer(rebasing: bytes[offset..<offset + len]))
                offset += len
            }
        }
        onFrame?(out, isKey, micros)
    }
}
