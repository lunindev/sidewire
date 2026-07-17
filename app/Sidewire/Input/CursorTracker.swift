import AppKit
import CoreGraphics

/// Source side: watches the global cursor and, whenever it sits over the streamed *virtual*
/// display, reports its normalized position so the Source can forward it to the Display, which
/// warps its own native hardware cursor there (see `Session.sendCursor` / `DisplayController`).
///
/// This is the out-of-band "local cursor" feed (the Parsec/Moonlight technique): the tiny
/// position message arrives at network latency while the video lags by encode+decode, so the
/// Display's native pointer tracks the user's hand far more smoothly than a cursor baked into
/// the video would. `config.showsCursor` stays false precisely so this can drive the pointer.
///
/// A global NSEvent monitor sees mouse-moved events destined for other apps / the extended
/// desktop without consuming them (they still reach their target). It needs no special
/// entitlement for mouse-moved (it's not a keylogger) and is best-effort.
@MainActor
final class CursorTracker {
    /// The streamed virtual display's `CGDirectDisplayID`. Set before `start()`.
    var virtualDisplayID: CGDirectDisplayID?
    /// Called on the main actor with normalized (x, y) whenever the cursor is over the virtual
    /// display: 0..1 within the display's bounds, TOP-LEFT origin (the INPUT/CURSOR wire
    /// convention). Not called while the pointer is on the Source's own screen(s).
    var onCursor: ((Float, Float) -> Void)?

    private var monitor: Any?

    func start() {
        stop() // idempotent — never orphan a prior monitor if start() is called twice
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged,
                                           .rightMouseDragged, .otherMouseDragged]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            // Global monitors deliver on the main thread; assumeIsolated keeps the pointer path
            // synchronous (no async hop / latency), matching InputCapture's local-monitor pattern.
            MainActor.assumeIsolated { self?.report() }
        }
        // Emit once now so the Display's cursor snaps to the current spot on connect, even before
        // the user moves (the monitor only fires on movement).
        report()
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// If the cursor currently sits over the virtual display, emit its normalized position.
    private func report() {
        guard let displayID = virtualDisplayID else { return }
        // NSEvent.mouseLocation is AppKit global (bottom-left origin); convert to CG global
        // (top-left) to compare with CGDisplayBounds, which is CG top-left.
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let mouse = NSEvent.mouseLocation
        let cg = CGPoint(x: mouse.x, y: primaryH - mouse.y)
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0, bounds.contains(cg) else { return }
        // Normalize over the full virtual display, TOP-LEFT origin — matching the wire convention
        // (InputCapture.normalizedLocation) so the Display maps it back into its video rect exactly.
        let nx = Float((cg.x - bounds.minX) / bounds.width)
        let ny = Float((cg.y - bounds.minY) / bounds.height)
        onCursor?(nx, ny)
    }
}
