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
    /// Key codes whose `.keyDown` we withheld locally (Cmd-combos, Esc). The matching `.keyUp`
    /// must be withheld too — otherwise the remote Mac receives a keyUp with no keyDown and its
    /// key state goes unbalanced (a key it thinks is still held, or a stray release).
    private var suppressedKeyCodes = Set<UInt16>()
    /// Key codes whose `.keyDown` we DID forward — the remote thinks these are held. A later
    /// suppressed repeat (e.g. ⌘ pressed while a forwarded key auto-repeats) must not swallow
    /// the keyUp the remote still needs, so suppression only starts for keys not in this set.
    private var forwardedKeyCodes = Set<UInt16>()

    // Left/right ⌘ virtual key codes and Esc — the keys that stay local.
    private static let leftCommandKeyCode: UInt16 = 55
    private static let rightCommandKeyCode: UInt16 = 54
    private static let escapeKeyCode: UInt16 = 53

    func start() {
        let eventMask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .leftMouseDragged, .rightMouseDragged, .scrollWheel,
            .keyDown, .keyUp, .flagsChanged
        ]

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            guard let self, self.isEnabled else { return event }

            // Keep ⌘-combos and Esc on THIS Mac (local shortcuts; Esc exits fullscreen), and do
            // it symmetrically so the remote never sees a half key stroke:
            switch event.type {
            case .keyDown:
                if event.modifierFlags.contains(.command) || event.keyCode == Self.escapeKeyCode {
                    // Withheld → remember the code so we drop its keyUp too. But if this key's
                    // original keyDown already went to the remote (⌘ arrived mid-auto-repeat),
                    // the remote still needs the keyUp — don't mark it suppressed.
                    if !self.forwardedKeyCodes.contains(event.keyCode) {
                        self.suppressedKeyCodes.insert(event.keyCode)
                    }
                    return event
                }
                self.forwardedKeyCodes.insert(event.keyCode)
            case .keyUp:
                // Mirror the keyDown decision by code (the ⌘ flag may already be gone on release).
                if self.suppressedKeyCodes.remove(event.keyCode) != nil { return event }
                self.forwardedKeyCodes.remove(event.keyCode)
            case .flagsChanged:
                // The ⌘ modifier is reserved for local shortcuts (we never forward ⌘-combos), so
                // never forward the ⌘ key's own press/release either — otherwise the remote Mac
                // would be left with Command stuck down and no combo to release it. Other
                // modifiers (Shift/Option/Control) still cross so remote Shift-click / Option-key
                // behavior works.
                if event.keyCode == Self.leftCommandKeyCode || event.keyCode == Self.rightCommandKeyCode {
                    return event
                }
            default:
                break
            }

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
        suppressedKeyCodes.removeAll() // don't carry a half-pressed key across sessions
        forwardedKeyCodes.removeAll()
    }

    private func handleEvent(_ event: NSEvent) {
        let type: InputEventType
        var macKey: UInt16 = 0
        var isKeyEvent = false
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
        // Scroll deltas cross the wire in pixels (macOS delivers pixel-precise deltas).
        case .scrollWheel: type = .scrollWheel; dx = Float(event.scrollingDeltaX); dy = Float(event.scrollingDeltaY)
        case .keyDown: type = .keyDown; macKey = event.keyCode; isKeyEvent = true
        case .keyUp: type = .keyUp; macKey = event.keyCode; isKeyEvent = true
        case .flagsChanged: type = .flagsChanged; macKey = event.keyCode; isKeyEvent = true
        default: return
        }

        // Translate the macOS virtual keycode → platform-neutral HID usage (v2 wire contract).
        // A key with no HID mapping is dropped (logged once by KeyMapping) rather than sent as 0.
        var hidUsage: UInt16 = 0
        if isKeyEvent {
            hidUsage = KeyMapping.hidUsage(fromMacVirtualKey: macKey)
            if hidUsage == 0 { return }
        }

        let (nx, ny) = normalizedLocation(for: event)

        let record = InputEventRecord(
            type: type, buttonNumber: bn, clickCount: cc,
            modifiers: KeyMapping.hidModifiers(from: event.modifierFlags),
            x: nx, y: ny, deltaX: dx, deltaY: dy, keyCode: hidUsage)
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
