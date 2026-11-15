import Foundation
import Network

/// Serves the viewer page over HTTP on `port` and streams video over a
/// WebSocket on `port + 1`. All client state lives on `queue`.
final class StreamServer {
    var onKeyframeRequest: (() -> Void)?
    var onInput: (([String: Any]) -> Void)?
    var onViewerCountChanged: ((Int) -> Void)?

    private let queue = DispatchQueue(label: "panebridge.server", qos: .userInteractive)
    private let page: Data
    private let width: Int
    private let height: Int
    private var httpListener: NWListener?
    private var wsListener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var codec: String?

    private final class Client {
        let connection: NWConnection
        var inFlight = 0
        var needsKeyframe = true
        init(_ c: NWConnection) { connection = c }
    }

    /// Frames allowed in the send queue before we start dropping (prevents lag build-up on slow Wi-Fi).
    private let maxInFlight = 4

    init(page: Data, width: Int, height: Int) {
        self.page = page
        self.width = width
        self.height = height
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
        let client = Client(conn)
        let id = ObjectIdentifier(client)
        clients[id] = client
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                print("Viewer connected: \(conn.endpoint)")
                self.onViewerCountChanged?(self.clients.count)
                if let codec { self.sendConfig(codec, to: client) }
                self.onKeyframeRequest?()
            case .failed, .cancelled:
                if self.clients.removeValue(forKey: id) != nil {
                    print("Viewer disconnected: \(conn.endpoint)")
                    self.onViewerCountChanged?(self.clients.count)
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
            if let error {
                _ = error
                client.connection.cancel()
                return
            }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if meta?.opcode == .close { client.connection.cancel(); return }
            if meta?.opcode == .text, let data,
               let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if msg["type"] as? String == "keyframe" {
                    client.needsKeyframe = true
                    self.onKeyframeRequest?()
                } else {
                    self.onInput?(msg)
                }
            }
            self.receive(client)
        }
    }

    func setCodec(_ codec: String) {
        queue.async { [self] in
            self.codec = codec
            print("Stream codec: \(codec)")
            for c in clients.values { sendConfig(codec, to: c) }
        }
    }

    private func sendConfig(_ codec: String, to client: Client) {
        let json = "{\"type\":\"config\",\"codec\":\"\(codec)\",\"width\":\(width),\"height\":\(height)}"
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "config", metadata: [meta])
        client.connection.send(content: Data(json.utf8), contentContext: ctx, isComplete: true, completion: .idempotent)
        client.needsKeyframe = true
    }

    /// Frame message: [u8 type=1][u8 keyframe][u64 BE timestamp µs][Annex-B H.264]
    func broadcast(frame: Data, isKey: Bool, timestamp: Int64) {
        queue.async { [self] in
            guard !clients.isEmpty else { return }
            var message = Data(capacity: frame.count + 10)
            message.append(1)
            message.append(isKey ? 1 : 0)
            withUnsafeBytes(of: UInt64(bitPattern: timestamp).bigEndian) { message.append(contentsOf: $0) }
            message.append(frame)

            var wantKey = false
            for client in clients.values {
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
                                       completion: .contentProcessed { _ in client.inFlight -= 1 })
            }
            if wantKey { onKeyframeRequest?() }
        }
    }
}
