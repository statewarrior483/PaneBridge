import Foundation
import CoreVideo
import WebRTC

/// Low-latency video over WebRTC (UDP). A lost packet only costs that one frame instead of
/// stalling the whole stream like TCP does, and libwebrtc adapts to the network on its own.
/// Signaling (offer/answer/ICE) rides on the existing WebSocket; input stays there too.
final class RTCStreamer: NSObject {
    /// Sends a signaling message to one viewer.
    var send: ((Int, [String: Any]) -> Void)?

    private static let setup: Void = {
        RTCInitializeSSL()
        RTCSetMinDebugLogLevel(.error)
    }()

    private let factory: RTCPeerConnectionFactory
    private let source: RTCVideoSource
    private let track: RTCVideoTrack
    private let frameCapturer: RTCVideoCapturer
    private let bitrate: Int
    private let fps: Int
    private let queue = DispatchQueue(label: "panebridge.rtc", qos: .userInteractive)
    private var peers: [Int: Peer] = [:]
    private let lock = NSLock()
    private var connectedCount = 0
    private var lastTimestamp: Int64 = 0

    init(width: Int, height: Int, fps: Int, bitrate: Int) {
        _ = Self.setup
        self.bitrate = bitrate
        self.fps = fps
        factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                           decoderFactory: RTCDefaultVideoDecoderFactory())
        source = factory.videoSource(forScreenCast: true)
        source.adaptOutputFormat(toWidth: Int32(width), height: Int32(height), fps: Int32(fps))
        track = factory.videoTrack(with: source, trackId: "screen")
        frameCapturer = RTCVideoCapturer(delegate: source)
        super.init()
    }

    /// Feeds a captured frame to every WebRTC viewer. Cheap no-op when there are none.
    func push(_ pixelBuffer: CVPixelBuffer, micros: Int64) {
        lock.lock(); let active = connectedCount > 0; lock.unlock()
        guard active else { return }
        // Timestamps must only go forward: an idle re-send is stamped "now", and the next real
        // frame's capture time can be slightly earlier, which would confuse the jitter buffer.
        let ts = max(micros, lastTimestamp + 1)
        lastTimestamp = ts
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
                                  rotation: ._0, timeStampNs: ts * 1000)
        source.capturer(frameCapturer, didCapture: frame)
    }

    func handle(_ id: Int, _ msg: [String: Any]) {
        queue.async { [self] in
            switch msg["type"] as? String {
            case "rtc-offer":
                guard let sdp = msg["sdp"] as? String else { return }
                answer(id, offer: sdp)
            case "rtc-ice":
                guard let peer = peers[id], let cand = msg["candidate"] as? String, !cand.isEmpty else { return }
                let ice = RTCIceCandidate(sdp: cand, sdpMLineIndex: Int32(msg["sdpMLineIndex"] as? Int ?? 0),
                                          sdpMid: msg["sdpMid"] as? String)
                if peer.remoteSet { peer.pc?.add(ice) { _ in } } else { peer.pending.append(ice) }
            default: break
            }
        }
    }

    func remove(_ id: Int) {
        queue.async { [self] in
            if let peer = peers.removeValue(forKey: id) { close(peer) }
        }
    }

    func stop() {
        queue.sync {
            for peer in peers.values { close(peer) }
            peers.removeAll()
        }
    }

    private func close(_ peer: Peer) {
        peer.setConnected(false)
        peer.pc?.close()
        peer.pc = nil
    }

    private func answer(_ id: Int, offer: String) {
        if let old = peers.removeValue(forKey: id) { close(old) }

        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = []                 // LAN / Tailscale only: host candidates are enough
        config.tcpCandidatePolicy = .disabled
        config.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

        let peer = Peer(id: id, owner: self)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: peer) else {
            send?(id, ["type": "rtc-error", "message": "Couldn't create a WebRTC connection"])
            return
        }
        peer.pc = pc
        peers[id] = peer

        pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: Self.raiseH264Level(offer))) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if let error { self.fail(id, "setRemoteDescription: \(error.localizedDescription)"); return }
                peer.remoteSet = true
                for c in peer.pending { pc.add(c) { _ in } }
                peer.pending.removeAll()
                // Attaches to the viewer's recvonly transceiver, making our side sendonly.
                let sender = pc.add(self.track, streamIds: ["screen"])
                pc.answer(for: constraints) { answer, error in
                    guard let answer else { self.fail(id, "createAnswer: \(error?.localizedDescription ?? "?")"); return }
                    pc.setLocalDescription(answer) { error in
                        self.queue.async {
                            if let error { self.fail(id, "setLocalDescription: \(error.localizedDescription)"); return }
                            self.send?(id, ["type": "rtc-answer", "sdp": answer.sdp])
                            if let sender { self.tune(sender, pc) }
                        }
                    }
                }
            }
        }
    }

    /// Keep full resolution (text stays sharp) and start at a sensible bitrate instead of
    /// WebRTC's slow ramp-up from a few hundred kbps.
    private func tune(_ sender: RTCRtpSender, _ pc: RTCPeerConnection) {
        let params = sender.parameters
        params.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainResolution.rawValue)
        for e in params.encodings {
            e.maxBitrateBps = NSNumber(value: bitrate)
            e.maxFramerate = NSNumber(value: fps)
            e.networkPriority = .high
        }
        sender.parameters = params
        pc.setBweMinBitrateBps(NSNumber(value: min(1_000_000, bitrate / 4)),
                               currentBitrateBps: NSNumber(value: bitrate / 2),
                               maxBitrateBps: NSNumber(value: bitrate))
    }

    /// Browsers offer H.264 at level 3.1 (720p max). VideoToolbox then refuses to encode 1080p+ and
    /// WebRTC silently falls back to software VP8. Declare level 5.2 instead; browsers' decoders
    /// don't enforce the level, and the offer already allows asymmetric levels.
    static func raiseH264Level(_ sdp: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "profile-level-id=(42e0|42c0|4d00|640c|6400)([0-9a-fA-F]{2})") else { return sdp }
        return re.stringByReplacingMatches(in: sdp, range: NSRange(sdp.startIndex..., in: sdp),
                                           withTemplate: "profile-level-id=$134")
    }

    private func fail(_ id: Int, _ message: String) {
        print("WebRTC: \(message)")
        send?(id, ["type": "rtc-error", "message": message])
    }

    fileprivate func connectionChanged(_ peer: Peer, connected: Bool) {
        lock.lock(); connectedCount += connected ? 1 : -1; lock.unlock()
        print(connected ? "WebRTC viewer \(peer.id) connected (UDP)" : "WebRTC viewer \(peer.id) disconnected")
    }

    fileprivate func candidate(_ peer: Peer, _ c: RTCIceCandidate) {
        send?(peer.id, ["type": "rtc-ice", "candidate": c.sdp, "sdpMid": c.sdpMid ?? "0", "sdpMLineIndex": Int(c.sdpMLineIndex)])
    }
}

private final class Peer: NSObject, RTCPeerConnectionDelegate {
    let id: Int
    weak var owner: RTCStreamer?
    var pc: RTCPeerConnection?
    var remoteSet = false
    var pending: [RTCIceCandidate] = []
    private var connected = false

    init(id: Int, owner: RTCStreamer) {
        self.id = id
        self.owner = owner
    }

    func setConnected(_ value: Bool) {
        guard value != connected else { return }
        connected = value
        owner?.connectionChanged(self, connected: value)
    }

    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        switch newState {
        case .connected, .completed: setConnected(true)
        case .failed, .closed, .disconnected: setConnected(false)
        default: break
        }
    }
    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        owner?.candidate(self, candidate)
    }
    func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
