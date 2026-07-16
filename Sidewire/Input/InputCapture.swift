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
    /// Mouse buttons whose press we forwarded — the remote thinks these are held. The exact
    /// counterpart of `forwardedKeyCodes`, and load-bearing in both directions: a press we
    /// forwarded MUST get its release even if the pointer has since left the video (otherwise the
    /// remote is stranded mid-drag), and a release whose press we never forwarded must be dropped
    /// (otherwise the click that re-takes the grab arrives as an unpaired mouseUp).
    private var forwardedButtons = Set<UInt8>()
    /// The last position we actually forwarded, so a synthesized release lands somewhere sane.
    private var lastForwardedPoint: (x: Float, y: Float) = (0, 0)

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
            // A local monitor is process-wide, so gate on the event actually being aimed at the
            // video window. Events carrying no window (some flagsChanged) pass through as before.
            if let eventWindow = event.window, let presenterWindow = self.presenter?.window,
               eventWindow !== presenterWindow {
                return event
            }

            // Keep ⌘-combos and Esc on THIS Mac (local shortcuts; Esc releases the grab), and do
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
        forwardedButtons.removeAll()
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

        // Mouse-button bookkeeping, mirroring the keyboard's. A release or drag for a button whose
        // press we never forwarded is meaningless to the remote — drop it.
        let button = Self.button(for: event.type)
        let isPress = (type == .mouseDown || type == .rightMouseDown)
        let isRelease = (type == .mouseUp || type == .rightMouseUp)
        let isDrag = (type == .mouseDragged || type == .rightMouseDragged)
        let gestureInFlight = (isRelease || isDrag) && button.map(forwardedButtons.contains) == true
        if (isRelease || isDrag), !gestureInFlight { return }

        // Off-video events are dropped rather than clamped: clamping a plain mouse-move to the
        // nearest edge — which is what this used to do — is what let the Source's cursor feed pin
        // the pointer against the video's border and trap it. Two kinds must still get through, so
        // they clamp instead: key events (the injector ignores their position anyway), and a
        // gesture already in flight — a held button's drag and release have to complete or the
        // remote Mac is left mid-drag with the button stuck down.
        let loc = normalizedLocation(for: event, clamping: isKeyEvent || gestureInFlight)
        if loc == nil, !isKeyEvent { return }
        let (nx, ny) = loc ?? (0, 0)

        if let button {
            if isPress { forwardedButtons.insert(button) }
            else if isRelease { forwardedButtons.remove(button) }
        }
        if !isKeyEvent { lastForwardedPoint = (nx, ny) }

        let record = InputEventRecord(
            type: type, buttonNumber: bn, clickCount: cc,
            modifiers: KeyMapping.hidModifiers(from: event.modifierFlags),
            x: nx, y: ny, deltaX: dx, deltaY: dy, keyCode: hidUsage)
        onInputEvent?(record)
    }

    /// The button an event belongs to, if any. Drags carry no usable `buttonNumber`, so it comes
    /// from the event type. 0 = left, 1 = right, matching `NSEvent.buttonNumber`.
    private static func button(for type: NSEvent.EventType) -> UInt8? {
        switch type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged: return 0
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged: return 1
        default: return nil
        }
    }

    /// Normalize the pointer into the rendered video rect (0..1). Without `clamping`, a pointer
    /// that isn't over the video — the letterbox bars, the title bar, outside the window — returns
    /// nil, meaning "not a point on the remote screen", which is a different thing from the nearest
    /// edge. Falls back to the full content view before the video size is known.
    private func normalizedLocation(for event: NSEvent, clamping: Bool) -> (Float, Float)? {
        guard let window = event.window else { return nil }
        if let presenter, presenter.window === window, presenter.bounds.width > 0 {
            let rect = presenter.videoRect
            if rect.width > 0, rect.height > 0 {
                let loc = presenter.convert(event.locationInWindow, from: nil)
                return normalize(x: (loc.x - rect.minX) / rect.width,
                                 y: 1.0 - (loc.y - rect.minY) / rect.height, clamping: clamping)
            }
        }
        let contentSize = window.contentView?.bounds.size ?? window.frame.size
        guard contentSize.width > 0, contentSize.height > 0 else { return nil }
        let loc = event.locationInWindow
        return normalize(x: loc.x / contentSize.width, y: 1.0 - loc.y / contentSize.height,
                         clamping: clamping)
    }

    private func normalize(x: CGFloat, y: CGFloat, clamping: Bool) -> (Float, Float)? {
        if clamping { return (Float(min(max(x, 0), 1)), Float(min(max(y, 0), 1))) }
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return (Float(x), Float(y))
    }

    /// Release everything the remote still believes is held — mouse buttons and keys — then forget
    /// all input state. Called when the grab drops: anything held at that instant would otherwise
    /// stay down on the remote Mac indefinitely, because its release is delivered to a monitor that
    /// is no longer forwarding. Must be called while the session is still open.
    func releaseHeldInput() {
        for button in forwardedButtons {
            onInputEvent?(InputEventRecord(type: button == 1 ? .rightMouseUp : .mouseUp,
                                           buttonNumber: button, clickCount: 1, modifiers: 0,
                                           x: lastForwardedPoint.x, y: lastForwardedPoint.y,
                                           deltaX: 0, deltaY: 0, keyCode: 0))
        }
        forwardedButtons.removeAll()
        for code in forwardedKeyCodes {
            let hid = KeyMapping.hidUsage(fromMacVirtualKey: code)
            guard hid != 0 else { continue }
            onInputEvent?(InputEventRecord(type: .keyUp, buttonNumber: 0, clickCount: 0,
                                           modifiers: 0, x: 0, y: 0, deltaX: 0, deltaY: 0,
                                           keyCode: hid))
        }
        forwardedKeyCodes.removeAll()
        suppressedKeyCodes.removeAll()
    }

    deinit { stop() }
}
