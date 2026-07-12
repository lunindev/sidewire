import AppKit
import SidewireProtocol

/// Captures keyboard/mouse on the Display and emits binary `InputEventRecord`s.
/// Pointer coordinates are normalized 0..1 within the *rendered video rect* (the aspect-fit
/// letterbox of the presenter), so clicks land on-target even when the stream's aspect ratio
/// differs from the panel. Cmd-combos and Esc are intentionally NOT forwarded so the user
/// always keeps control of the Display Mac and can exit immersive mode.
final class InputCapture {
    var onInputEvent: ((InputEventRecord) -> Void)?
    var isEnabled = false
    /// The view whose aspect-fit video rect input maps into. Weak — owned by DisplayController.
    weak var presenter: VideoPresenterView?

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

        let (nx, ny) = normalizedLocation(for: event)

        let record = InputEventRecord(
            type: type, buttonNumber: bn, clickCount: cc,
            modifierFlags: UInt64(event.modifierFlags.rawValue),
            x: nx, y: ny, deltaX: dx, deltaY: dy, keyCode: kc)
        onInputEvent?(record)
    }

    /// Normalize the pointer into the rendered video rect (0..1). A point inside the view but
    /// outside the letterboxed video clamps to the nearest edge. Falls back to the full content
    /// view before the video size is known (or if the presenter is detached).
    private func normalizedLocation(for event: NSEvent) -> (Float, Float) {
        guard let window = event.window else { return (0, 0) }
        if let presenter, presenter.window === window, presenter.bounds.width > 0 {
            let rect = presenter.videoRect
            if rect.width > 0, rect.height > 0 {
                let loc = presenter.convert(event.locationInWindow, from: nil)
                let nx = ((loc.x - rect.minX) / rect.width).clamped(0, 1)
                let ny = (1.0 - (loc.y - rect.minY) / rect.height).clamped(0, 1)
                return (Float(nx), Float(ny))
            }
        }
        let contentSize = window.contentView?.bounds.size ?? window.frame.size
        guard contentSize.width > 0, contentSize.height > 0 else { return (0, 0) }
        let loc = event.locationInWindow
        return (Float((loc.x / contentSize.width).clamped(0, 1)),
                Float((1.0 - loc.y / contentSize.height).clamped(0, 1)))
    }

    deinit { stop() }
}

private extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { Swift.min(Swift.max(self, lo), hi) }
}
