import AppKit

final class InputCapture {
    var onInputEvent: ((InputEvent) -> Void)?
    var isEnabled = false

    private var localMonitor: Any?

    func start() {
        let eventMask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .leftMouseDragged, .rightMouseDragged, .scrollWheel,
            .keyDown, .keyUp, .flagsChanged
        ]

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            guard let self, self.isEnabled else { return event }

            if event.type == .keyDown, event.modifierFlags.contains(.command) {
                return event
            }

            if event.type == .keyDown, event.keyCode == 53 {
                return event
            }

            self.handleEvent(event)

            switch event.type {
            case .keyDown, .keyUp:
                return nil
            default:
                return event
            }
        }
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
    }

    private func handleEvent(_ event: NSEvent) {
        let type: InputEventType
        var kc: UInt16 = 0
        var dx = 0.0
        var dy = 0.0
        var cc = 0
        var bn = 0

        switch event.type {
        case .mouseMoved:
            type = .mouseMove
        case .leftMouseDown:
            type = .mouseDown; cc = event.clickCount; bn = event.buttonNumber
        case .leftMouseUp:
            type = .mouseUp; cc = event.clickCount; bn = event.buttonNumber
        case .rightMouseDown:
            type = .rightMouseDown; cc = event.clickCount; bn = event.buttonNumber
        case .rightMouseUp:
            type = .rightMouseUp; cc = event.clickCount; bn = event.buttonNumber
        case .leftMouseDragged:
            type = .mouseDragged
        case .rightMouseDragged:
            type = .rightMouseDragged
        case .scrollWheel:
            type = .scrollWheel
            dx = event.scrollingDeltaX
            dy = event.scrollingDeltaY
        case .keyDown:
            type = .keyDown; kc = event.keyCode
        case .keyUp:
            type = .keyUp; kc = event.keyCode
        case .flagsChanged:
            type = .flagsChanged; kc = event.keyCode
        default:
            return
        }

        var normalizedX = 0.0
        var normalizedY = 0.0

        if let window = event.window {
            let contentSize = window.contentView?.bounds.size ?? window.frame.size
            let loc = event.locationInWindow
            normalizedX = Double(loc.x / contentSize.width).clamped(to: 0...1)
            normalizedY = Double(1.0 - loc.y / contentSize.height).clamped(to: 0...1)
        }

        let inputEvent = InputEvent(
            type: type,
            x: normalizedX,
            y: normalizedY,
            deltaX: dx,
            deltaY: dy,
            keyCode: kc,
            modifierFlags: UInt(event.modifierFlags.rawValue),
            clickCount: cc,
            buttonNumber: bn
        )

        onInputEvent?(inputEvent)
    }

    deinit {
        stop()
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
