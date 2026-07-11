import AppKit
import SidewireProtocol

/// Captures keyboard/mouse on the Display and emits binary `InputEventRecord`s.
/// Ported from the previous app; coordinates are normalized 0..1 within the content
/// view. Cmd-combos and Esc are intentionally NOT forwarded so the user always keeps
/// control of the Display Mac and can exit immersive mode.
final class InputCapture {
    var onInputEvent: ((InputEventRecord) -> Void)?
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
            if event.type == .keyDown, event.modifierFlags.contains(.command) { return event }
            if event.type == .keyDown, event.keyCode == 53 { return event } // Esc

            self.handleEvent(event)
            switch event.type {
            case .keyDown, .keyUp: return nil
            default: return event
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
        var dx: Float = 0
        var dy: Float = 0
        var cc: UInt8 = 0
        var bn: UInt8 = 0

        switch event.type {
        case .mouseMoved: type = .mouseMove
        case .leftMouseDown: type = .mouseDown; cc = UInt8(clamping: event.clickCount); bn = UInt8(clamping: event.buttonNumber)
        case .leftMouseUp: type = .mouseUp; cc = UInt8(clamping: event.clickCount); bn = UInt8(clamping: event.buttonNumber)
        case .rightMouseDown: type = .rightMouseDown; cc = UInt8(clamping: event.clickCount); bn = UInt8(clamping: event.buttonNumber)
        case .rightMouseUp: type = .rightMouseUp; cc = UInt8(clamping: event.clickCount); bn = UInt8(clamping: event.buttonNumber)
        case .leftMouseDragged: type = .mouseDragged
        case .rightMouseDragged: type = .rightMouseDragged
        case .scrollWheel: type = .scrollWheel; dx = Float(event.scrollingDeltaX); dy = Float(event.scrollingDeltaY)
        case .keyDown: type = .keyDown; kc = event.keyCode
        case .keyUp: type = .keyUp; kc = event.keyCode
        case .flagsChanged: type = .flagsChanged; kc = event.keyCode
        default: return
        }

        var nx: Float = 0
        var ny: Float = 0
        if let window = event.window {
            let contentSize = window.contentView?.bounds.size ?? window.frame.size
            let loc = event.locationInWindow
            if contentSize.width > 0, contentSize.height > 0 {
                nx = Float((loc.x / contentSize.width).clamped(0, 1))
                ny = Float((1.0 - loc.y / contentSize.height).clamped(0, 1))
            }
        }

        let record = InputEventRecord(
            type: type, buttonNumber: bn, clickCount: cc,
            modifierFlags: UInt64(event.modifierFlags.rawValue),
            x: nx, y: ny, deltaX: dx, deltaY: dy, keyCode: kc)
        onInputEvent?(record)
    }

    deinit { stop() }
}

private extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { Swift.min(Swift.max(self, lo), hi) }
}
