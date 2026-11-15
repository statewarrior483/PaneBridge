import Foundation
import Network

/// Serves the viewer page over HTTP on `port` and runs a WebSocket on `port + 1` that carries
/// control messages, input, WebRTC signaling and (for viewers not using WebRTC) the video
/// itself. All client state lives on `queue`.
final class StreamServer {
    var onKeyframeRequest: (() -> Void)?
    var onInput: (([String: Any]) -> Void)?
    var onViewerCountChanged: ((Int) -> Void)?
    /// Called (on the server queue) when a backed-up viewer has caught up again.
    var onDrained: (() -> Void)?
    /// WebRTC signaling message from a viewer (offer / ICE candidate).
    var onSignal: ((Int, [String: Any]) -> Void)?
    /// A viewer disconnected.
    var onClientGone: ((Int) -> Void)?
    /// True while at least one viewer is controlling the Mac with its own local cursor.
    var onLocalCursorChanged: ((Bool) -> Void)?

    /// True while any viewer still has a frame waiting to be sent. The capturer
    /// checks this and skips encoding instead of piling frames into the socket,
    /// which keeps latency low without breaking the H.264 reference chain.
    var isBackedUp: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return backedUp
    }
    /// True if any viewer gets video over this WebSocket (rather than WebRTC).
    var wantsEncodedFrames: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return encodedViewers > 0
    }
    private let stateLock = NSLock()
    private var backedUp = false
    private var encodedViewers = 0
    private var localCursor = false

    private func updateState() {
        let frameClients = clients.values.filter { $0.wantsFrames }
        let nowBacked = frameClients.contains { $0.inFlight >= sendWindow }
        stateLock.lock()
        let was = backedUp
        backedUp = nowBacked
        encodedViewers = frameClients.count
        stateLock.unlock()
        if was && !nowBacked { onDrained?() }

        let cursor = clients.values.contains { $0.localCursor }
        if cursor != localCursor { localCursor = cursor; onLocalCursorChanged?(cursor) }
    }

    private let queue = DispatchQueue(label: "panebridge.server", qos: .userInteractive)
    private let page: Data
    private let width: Int
    private let height: Int
    private let pointWidth: Int
    private let pointHeight: Int
    private let inputEnabled: Bool
    private var httpListener: NWListener?
    private var wsListener: NWListener?
    private var clients: [Int: Client] = [:]
    private var nextID = 1
    private var codec: String?
    private var cursorMessage: Data?

    private final class Client {
        let id: Int
        let connection: NWConnection
        var inFlight = 0
        var needsKeyframe = true
        /// Gets H.264 frames over the WebSocket. False once the viewer switches to WebRTC.
        var wantsFrames = true
        var localCursor = false
        init(_ id: Int, _ c: NWConnection) { self.id = id; connection = c }
    }

    /// Frames allowed in the send queue before we start dropping (prevents lag build-up on slow Wi-Fi).
    private let maxInFlight = 12
    /// Frames allowed on the wire per viewer before new frames are skipped at the encoder.
    private let sendWindow = 2

    init(page: Data, width: Int, height: Int, pointWidth: Int, pointHeight: Int, inputEnabled: Bool) {
        self.page = page
        self.width = width
        self.height = height
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.inputEnabled = inputEnabled
    }

    func start(port: UInt16) throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true

        let http = try NWListener(using: NWParameters(tls: nil, tcp: tcp), on: NWEndpoint.Port(rawValue: port)!)
        http.newConnectionHandler = { [weak self] in self?.serveHTTP($0) }
        http.stateUpdateHandler = { if case .failed(let e) = $0 { print("HTTP server failed: \(e)"); exit(1) } }
        http.start(queue: queue)
        httpListener = http

        let wsParams = NWParameters(tls: nil, tcp: tcp)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        wsParams.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let wsl = try NWListener(using: wsParams, on: NWEndpoint.Port(rawValue: port + 1)!)
        wsl.newConnectionHandler = { [weak self] in self?.accept($0) }
        wsl.stateUpdateHandler = { if case .failed(let e) = $0 { print("WebSocket server failed: \(e)"); exit(1) } }
        wsl.start(queue: queue)
        wsListener = wsl
    }

    func stop() {
        queue.sync {
            httpListener?.cancel()
            wsListener?.cancel()
            for c in clients.values { c.connection.cancel() }
            clients.removeAll()
        }
    }

    // MARK: HTTP (just the one page)

    private func serveHTTP(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [page] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            var response: Data
            if path == "/" || path.hasPrefix("/?") || path == "/index.html" {
                response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
                response.append(page)
            } else {
                response = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            }
            conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    // MARK: WebSocket

    private func accept(_ conn: NWConnection) {
        let client = Client(nextID, conn)
        nextID += 1
        let id = client.id
        clients[id] = client
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                print("Viewer connected: \(conn.endpoint)")
                self.onViewerCountChanged?(self.clients.count)
                self.sendConfig(to: client)
                if let cursorMessage { self.sendText(cursorMessage, to: client) }
                self.updateState()
                self.onKeyframeRequest?()
            case .failed, .cancelled:
                if self.clients.removeValue(forKey: id) != nil {
                    print("Viewer disconnected: \(conn.endpoint)")
                    self.onViewerCountChanged?(self.clients.count)
                    self.updateState()
                    self.onClientGone?(id)
                }
            default: break
            }
        }
        conn.start(queue: queue)
        receive(client)
    }

    private func receive(_ client: Client) {
        client.connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error != nil { client.connection.cancel(); return }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if meta?.opcode == .close { client.connection.cancel(); return }
            if meta?.opcode == .text, let data,
               let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.handle(msg, from: client)
            }
            self.receive(client)
        }
    }

    private func handle(_ msg: [String: Any], from client: Client) {
        let type = msg["type"] as? String ?? ""
        switch type {
        case "ping":
            // Clock sync for the latency readout: echo the viewer's time plus ours.
            let t = msg["t"] as? Double ?? 0
            sendText(Data("{\"type\":\"pong\",\"t\":\(t),\"s\":\(hostMicros())}".utf8), to: client)
        case "keyframe":
            client.needsKeyframe = true
            onKeyframeRequest?()
        case "transport":
            let wants = (msg["mode"] as? String) != "webrtc"
            if wants != client.wantsFrames {
                client.wantsFrames = wants
                client.needsKeyframe = true
                updateState()
                if wants { onKeyframeRequest?() }
            }
        case "control":
            client.localCursor = (msg["localCursor"] as? Bool ?? false) && inputEnabled
            updateState()
        case _ where type.hasPrefix("rtc-"):
            onSignal?(client.id, msg)
        default:
            onInput?(msg)
        }
    }

    /// Sends a JSON message to one viewer, or to all of them when `to` is nil. Thread-safe.
    func send(json: [String: Any], to id: Int?) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        queue.async { [self] in
            if let id { if let c = clients[id] { sendText(data, to: c) } }
            else { for c in clients.values { sendText(data, to: c) } }
        }
    }

    /// The Mac's current cursor image; remembered for viewers that connect later.
    func setCursor(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        queue.async { [self] in
            cursorMessage = data
            for c in clients.values { sendText(data, to: c) }
        }
    }

    private func sendText(_ data: Data, to client: Client) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        client.connection.send(content: data, contentContext: ctx, isComplete: true, completion: .idempotent)
    }

    func setCodec(_ codec: String) {
        queue.async { [self] in
            guard codec != self.codec else { return }
            self.codec = codec
            print("Stream codec: \(codec)")
            for c in clients.values { sendConfig(to: c) }
        }
    }

    private func sendConfig(to client: Client) {
        var json: [String: Any] = ["type": "config", "width": width, "height": height,
                                   "pointWidth": pointWidth, "pointHeight": pointHeight, "input": inputEnabled]
        if let codec { json["codec"] = codec }
        if let data = try? JSONSerialization.data(withJSONObject: json) { sendText(data, to: client) }
        client.needsKeyframe = true
    }

    /// Frame message: [u8 type=1][u8 keyframe][u64 BE capture timestamp µs][Annex-B H.264]
    func broadcast(frame: Data, isKey: Bool, timestamp: Int64) {
        queue.async { [self] in
            guard clients.values.contains(where: { $0.wantsFrames }) else { return }
            var message = Data(capacity: frame.count + 10)
            message.append(1)
            message.append(isKey ? 1 : 0)
            withUnsafeBytes(of: UInt64(bitPattern: timestamp).bigEndian) { message.append(contentsOf: $0) }
            message.append(frame)

            var wantKey = false
            for client in clients.values where client.wantsFrames {
                if client.needsKeyframe && !isKey { wantKey = true; continue }
                if client.inFlight >= maxInFlight && !isKey {
                    // Viewer is falling behind: drop until the next keyframe to catch up.
                    client.needsKeyframe = true
                    wantKey = true
                    continue
                }
                client.needsKeyframe = false
                client.inFlight += 1
                let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
                let ctx = NWConnection.ContentContext(identifier: "frame", metadata: [meta])
                client.connection.send(content: message, contentContext: ctx, isComplete: true,
                                       completion: .contentProcessed { [weak self] _ in
                                           client.inFlight -= 1
                                           self?.updateState()
                                       })
            }
            updateState()
            if wantKey { onKeyframeRequest?() }
        }
    }
}
