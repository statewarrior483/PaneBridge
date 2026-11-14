import Foundation
import CoreGraphics

/// Turns mouse/keyboard messages from the viewer into real macOS input events
/// on the virtual display. Needs Accessibility permission.
final class InputInjector {
    private let displayID: CGDirectDisplayID
    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttonsDown = Set<Int>()

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    func handle(_ msg: [String: Any]) {
        switch msg["type"] as? String {
        case "mouse": mouse(msg)
        case "wheel": wheel(msg)
        case "key": key(msg)
        default: break
        }
    }

    private func point(_ msg: [String: Any]) -> CGPoint {
        let b = CGDisplayBounds(displayID)
        let x = min(max(msg["x"] as? Double ?? 0, 0), 0.9999)
        let y = min(max(msg["y"] as? Double ?? 0, 0), 0.9999)
        return CGPoint(x: b.minX + x * b.width, y: b.minY + y * b.height)
    }

    private func flags(_ msg: [String: Any]) -> CGEventFlags {
        let m = msg["mods"] as? [String: Bool] ?? [:]
        var f: CGEventFlags = []
        if m["cmd"] == true { f.insert(.maskCommand) }
        if m["ctrl"] == true { f.insert(.maskControl) }
        if m["alt"] == true { f.insert(.maskAlternate) }
        if m["shift"] == true { f.insert(.maskShift) }
        return f
    }

    private func mouse(_ msg: [String: Any]) {
        let p = point(msg)
        let jsButton = msg["button"] as? Int ?? 0
        let button: CGMouseButton = jsButton == 2 ? .right : (jsButton == 1 ? .center : .left)
        let type: CGEventType
        var cgButton = button
        switch msg["action"] as? String {
        case "down":
            buttonsDown.insert(jsButton)
            type = button == .left ? .leftMouseDown : (button == .right ? .rightMouseDown : .otherMouseDown)
        case "up":
            buttonsDown.remove(jsButton)
            type = button == .left ? .leftMouseUp : (button == .right ? .rightMouseUp : .otherMouseUp)
        default:
            if buttonsDown.contains(0) { type = .leftMouseDragged; cgButton = .left }
            else if buttonsDown.contains(2) { type = .rightMouseDragged; cgButton = .right }
            else if buttonsDown.contains(1) { type = .otherMouseDragged; cgButton = .center }
            else { type = .mouseMoved }
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: cgButton) else { return }
        if let clicks = msg["clicks"] as? Int, clicks > 0 {
            e.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        }
        e.flags = flags(msg)
        e.post(tap: .cghidEventTap)
    }

    private func wheel(_ msg: [String: Any]) {
        let dx = msg["dx"] as? Double ?? 0
        let dy = msg["dy"] as? Double ?? 0
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: Int32(-dy.rounded()), wheel2: Int32(-dx.rounded()), wheel3: 0) else { return }
        e.location = point(msg)
        e.flags = flags(msg)
        e.post(tap: .cghidEventTap)
    }

    private func key(_ msg: [String: Any]) {
        guard let code = msg["code"] as? String, let keyCode = Self.keyCodes[code] else { return }
        let down = msg["action"] as? String == "down"
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
        e.flags = flags(msg)
        e.post(tap: .cghidEventTap)
    }

    /// Browser KeyboardEvent.code -> macOS virtual key code (ANSI layout positions).
    /// Modifier keys are not sent on their own; they ride along as flags.
    private static let keyCodes: [String: CGKeyCode] = [
        "KeyA": 0x00, "KeyS": 0x01, "KeyD": 0x02, "KeyF": 0x03, "KeyH": 0x04, "KeyG": 0x05, "KeyZ": 0x06,
        "KeyX": 0x07, "KeyC": 0x08, "KeyV": 0x09, "IntlBackslash": 0x0A, "KeyB": 0x0B, "KeyQ": 0x0C,
        "KeyW": 0x0D, "KeyE": 0x0E, "KeyR": 0x0F, "KeyY": 0x10, "KeyT": 0x11, "Digit1": 0x12, "Digit2": 0x13,
        "Digit3": 0x14, "Digit4": 0x15, "Digit6": 0x16, "Digit5": 0x17, "Equal": 0x18, "Digit9": 0x19,
        "Digit7": 0x1A, "Minus": 0x1B, "Digit8": 0x1C, "Digit0": 0x1D, "BracketRight": 0x1E, "KeyO": 0x1F,
        "KeyU": 0x20, "BracketLeft": 0x21, "KeyI": 0x22, "KeyP": 0x23, "Enter": 0x24, "KeyL": 0x25,
        "KeyJ": 0x26, "Quote": 0x27, "KeyK": 0x28, "Semicolon": 0x29, "Backslash": 0x2A, "Comma": 0x2B,
        "Slash": 0x2C, "KeyN": 0x2D, "KeyM": 0x2E, "Period": 0x2F, "Tab": 0x30, "Space": 0x31,
        "Backquote": 0x32, "Backspace": 0x33, "Escape": 0x35, "CapsLock": 0x39,
        "NumpadDecimal": 0x41, "NumpadMultiply": 0x43, "NumpadAdd": 0x45, "NumLock": 0x47,
        "NumpadDivide": 0x4B, "NumpadEnter": 0x4C, "NumpadSubtract": 0x4E, "NumpadEqual": 0x51,
        "Numpad0": 0x52, "Numpad1": 0x53, "Numpad2": 0x54, "Numpad3": 0x55, "Numpad4": 0x56,
        "Numpad5": 0x57, "Numpad6": 0x58, "Numpad7": 0x59, "Numpad8": 0x5B, "Numpad9": 0x5C,
        "F1": 0x7A, "F2": 0x78, "F3": 0x63, "F4": 0x76, "F5": 0x60, "F6": 0x61, "F7": 0x62, "F8": 0x64,
        "F9": 0x65, "F10": 0x6D, "F11": 0x67, "F12": 0x6F,
        "Insert": 0x72, "Home": 0x73, "PageUp": 0x74, "Delete": 0x75, "End": 0x77, "PageDown": 0x79,
        "ArrowLeft": 0x7B, "ArrowRight": 0x7C, "ArrowDown": 0x7D, "ArrowUp": 0x7E,
    ]
}
