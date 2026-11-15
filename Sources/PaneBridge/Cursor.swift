import AppKit

/// Remembers where the PC last put the pointer, so pointer movement anywhere else can be
/// recognised as the Mac's own trackpad/mouse. Thread-safe.
final class PointerTracker {
    private let lock = NSLock()
    private var injected: CGPoint?

    func noteInjected(_ p: CGPoint) {
        lock.lock(); injected = p; lock.unlock()
    }

    func isInjected(_ p: CGPoint) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let q = injected else { return false }
        return abs(q.x - p.x) <= 1.5 && abs(q.y - p.y) <= 1.5
    }
}

/// Watches the Mac's pointer for the PC viewer:
/// - its current shape (arrow, I-beam, resize, …), so the PC can draw the same pointer locally.
///   A locally drawn pointer moves instantly; one drawn into the video needs a round trip.
/// - its position whenever the Mac's own trackpad/mouse moves it on the PaneBridge display,
///   so the PC can show where it is (the video itself leaves the pointer out).
final class CursorWatcher {
    /// Cursor shape changed.
    var onChange: (([String: Any]) -> Void)?
    /// The Mac's own mouse moved: position on the virtual display (0…1), or nil when it left it.
    var onPointer: (([String: Any]) -> Void)?

    private let displayID: CGDirectDisplayID
    private let tracker: PointerTracker
    private var timer: DispatchSourceTimer?
    private var last: Data?
    private var lastPos: CGPoint?
    private var macPointerShown = false
    private var tickCount = 0

    init(displayID: CGDirectDisplayID, tracker: PointerTracker) {
        self.displayID = displayID
        self.tracker = tracker
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        tickCount += 1
        trackPosition()
        if tickCount % 3 == 0 { checkShape() }
    }

    private func trackPosition() {
        guard let p = CGEvent(source: nil)?.location else { return }  // global, top-left origin
        defer { lastPos = p }
        guard let prev = lastPos, prev != p else { return }
        // Moved by the PC (an event we posted): the PC already draws its own pointer.
        if tracker.isInjected(p) { return }

        let b = CGDisplayBounds(displayID)
        if b.contains(p) {
            macPointerShown = true
            onPointer?(["type": "pointer", "visible": true,
                        "x": (p.x - b.minX) / b.width, "y": (p.y - b.minY) / b.height])
        } else if macPointerShown {
            macPointerShown = false
            onPointer?(["type": "pointer", "visible": false])
        }
    }

    private func checkShape() {
        guard let cursor = NSCursor.currentSystem else { return }
        let image = cursor.image
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { return }
        let hot = cursor.hotSpot
        var key = png
        withUnsafeBytes(of: (hot.x, hot.y)) { key.append(contentsOf: $0) }
        guard key != last else { return }
        last = key
        onChange?(["type": "cursor", "png": png.base64EncodedString(),
                   "w": image.size.width, "h": image.size.height, "hx": hot.x, "hy": hot.y])
    }
}
