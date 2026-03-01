import Foundation
import CoreGraphics

final class InputInjector {
    var virtualDisplayID: CGDirectDisplayID?

    func inject(event: InputEvent) {
        let point = mapToDisplay(x: event.x, y: event.y)

        switch event.type {
        case .mouseMove:
            postMouse(.mouseMoved, at: point, button: .left)
        case .mouseDown:
            postMouse(.leftMouseDown, at: point, button: .left, clickCount: event.clickCount)
        case .mouseUp:
            postMouse(.leftMouseUp, at: point, button: .left, clickCount: event.clickCount)
        case .rightMouseDown:
            postMouse(.rightMouseDown, at: point, button: .right, clickCount: event.clickCount)
        case .rightMouseUp:
            postMouse(.rightMouseUp, at: point, button: .right, clickCount: event.clickCount)
        case .mouseDragged:
            postMouse(.leftMouseDragged, at: point, button: .left)
        case .rightMouseDragged:
            postMouse(.rightMouseDragged, at: point, button: .right)
        case .scrollWheel:
            if let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(event.deltaY), wheel2: Int32(event.deltaX), wheel3: 0) {
                scrollEvent.location = point
                scrollEvent.post(tap: .cghidEventTap)
            }
        case .keyDown:
            postKey(keyCode: event.keyCode, keyDown: true, flags: event.modifierFlags)
        case .keyUp:
            postKey(keyCode: event.keyCode, keyDown: false, flags: event.modifierFlags)
        case .flagsChanged:
            if let flagEvent = CGEvent(keyboardEventSource: nil, virtualKey: event.keyCode, keyDown: true) {
                flagEvent.type = .flagsChanged
                flagEvent.flags = CGEventFlags(rawValue: UInt64(event.modifierFlags))
                flagEvent.post(tap: .cghidEventTap)
            }
        }
    }

    private func mapToDisplay(x: Double, y: Double) -> CGPoint {
        if let displayID = virtualDisplayID {
            let bounds = CGDisplayBounds(displayID)
            return CGPoint(
                x: bounds.origin.x + x * bounds.width,
                y: bounds.origin.y + y * bounds.height
            )
        }
        return CGPoint(x: x * 2560, y: y * 1600)
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clickCount: Int = 1) {
        if let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickCount)))
            event.post(tap: .cghidEventTap)
        }
    }

    private func postKey(keyCode: UInt16, keyDown: Bool, flags: UInt) {
        if let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown) {
            event.flags = CGEventFlags(rawValue: UInt64(flags))
            event.post(tap: .cghidEventTap)
        }
    }
}
