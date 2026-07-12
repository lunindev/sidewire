import Foundation
import CoreGraphics
import SidewireProtocol

/// Injects `InputEventRecord`s as CGEvents on the Source, mapped onto the virtual
/// display's bounds. Ported from the previous app.
///
/// Phase 3 gates this on pairing (refuse injection from an unpaired peer). For now it
/// injects whatever the connected Display sends.
final class InputInjector {
    var virtualDisplayID: CGDirectDisplayID?
    /// When false, incoming input is dropped instead of injected (e.g. Accessibility was
    /// revoked mid-session, so CGEvent posts would silently no-op). Toggled from the main
    /// actor; the benign read/write race on a Bool matches the existing `virtualDisplayID`
    /// pattern and is acceptable for a best-effort gate.
    var injectionEnabled = true

    func inject(event: InputEventRecord) {
        guard injectionEnabled else { return }
        let point = mapToDisplay(x: Double(event.x), y: Double(event.y))
        // Translate the platform-neutral HID modifier byte → macOS CGEventFlags (v2 wire contract).
        let flags = KeyMapping.cgEventFlags(fromHIDModifiers: event.modifiers)

        switch event.type {
        case .mouseMove:
            postMouse(.mouseMoved, at: point, button: .left)
        case .mouseDown:
            postMouse(.leftMouseDown, at: point, button: .left, clickCount: Int(event.clickCount))
        case .mouseUp:
            postMouse(.leftMouseUp, at: point, button: .left, clickCount: Int(event.clickCount))
        case .rightMouseDown:
            postMouse(.rightMouseDown, at: point, button: .right, clickCount: Int(event.clickCount))
        case .rightMouseUp:
            postMouse(.rightMouseUp, at: point, button: .right, clickCount: Int(event.clickCount))
        case .mouseDragged:
            postMouse(.leftMouseDragged, at: point, button: .left)
        case .rightMouseDragged:
            postMouse(.rightMouseDragged, at: point, button: .right)
        case .scrollWheel:
            // Wire deltas are pixels; inject as pixel-unit scroll.
            if let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                    wheel1: Int32(event.deltaY), wheel2: Int32(event.deltaX), wheel3: 0) {
                scroll.location = point
                scroll.post(tap: .cghidEventTap)
            }
        case .keyDown:
            // HID usage → macOS virtual keycode; unmapped usages are dropped (logged once).
            guard let macKey = KeyMapping.macVirtualKey(fromHIDUsage: event.keyCode) else { return }
            postKey(keyCode: macKey, keyDown: true, flags: flags)
        case .keyUp:
            guard let macKey = KeyMapping.macVirtualKey(fromHIDUsage: event.keyCode) else { return }
            postKey(keyCode: macKey, keyDown: false, flags: flags)
        case .flagsChanged:
            guard let macKey = KeyMapping.macVirtualKey(fromHIDUsage: event.keyCode) else { return }
            if let flagEvent = CGEvent(keyboardEventSource: nil, virtualKey: macKey, keyDown: true) {
                flagEvent.type = .flagsChanged
                flagEvent.flags = flags
                flagEvent.post(tap: .cghidEventTap)
            }
        }
    }

    private func mapToDisplay(x: Double, y: Double) -> CGPoint {
        if let displayID = virtualDisplayID {
            let bounds = CGDisplayBounds(displayID)
            return CGPoint(x: bounds.origin.x + x * bounds.width, y: bounds.origin.y + y * bounds.height)
        }
        return CGPoint(x: x * 2560, y: y * 1600)
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clickCount: Int = 1) {
        if let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickCount)))
            event.post(tap: .cghidEventTap)
        }
    }

    private func postKey(keyCode: UInt16, keyDown: Bool, flags: CGEventFlags) {
        if let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown) {
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }
}
