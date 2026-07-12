import Foundation

/// Manages a self-healing connection: dial → run a Session → on an unexpected drop,
/// re-dial with exponential backoff + jitter, indefinitely. A fresh Session (and fresh
/// transport) is created on each attempt, so re-dialing a Bonjour `.service` endpoint
/// re-resolves it (this is why reconnection now works in discovery mode, not just
/// manual-IP). Lives above the per-connection Session, in SidewireCore, so it is
/// exercised by the loopback test harness.
///
/// The caller supplies `makeSession` (creates a not-yet-started Session with a fresh
/// transport) and wires media callbacks in `onSession`. The Reconnector owns the
/// Session's lifecycle callbacks (onPhaseChange/onClosed) and surfaces one `LinkState`.
public final class Reconnector: @unchecked Sendable {
    public enum LinkState: Sendable, Equatable {
        case connecting
        case streaming
        case reconnecting(attempt: Int)
        case stopped
        case failed(String)
    }

    public var onState: ((LinkState) -> Void)?
    /// Called with each freshly-created (not-yet-started) Session so the caller can wire
    /// media callbacks (onReady/onVideoFrame/onInputEvent/onDisplayInfo/provideDisplayInfo)
    /// before it starts. Invoked on the reconnector's queue.
    public var onSession: ((Session) -> Void)?

    /// Reasons that must NOT trigger auto-reconnect (explicit teardown / fatal handshake).
    /// "auth" = wrong PIN: re-dialing with the same wrong PSK can only fail again, so stop
    /// and let the UI prompt for the correct PIN. "superseded" = another Source took the
    /// Display; re-dialing would just fight the taker forever (newest-wins → steal loop).
    private static let fatalReasons: Set<String> = [
        "user", "protocol", "role",
        SessionConstants.authFailureReason,
        SessionConstants.supersededReason,
    ]

    private let makeSession: () -> Session
    private let queue = DispatchQueue(label: "sidewire.reconnector")
    private var current: Session?
    private var stopped = false
    private var started = false
    private var attempt = 0
    /// Bumped on start()/stop() to invalidate any pending backoff dial.
    private var generation = 0

    public init(makeSession: @escaping () -> Session) {
        self.makeSession = makeSession
    }

    public func start() {
        queue.async {
            guard !self.started else { return } // single-use: ignore double start
            self.started = true
            self.stopped = false
            self.attempt = 0
            self.generation &+= 1
            self.dial()
        }
    }

    public func stop() {
        queue.async {
            self.stopped = true
            self.generation &+= 1 // cancels any pending backoff dial
            self.current?.close(reason: "user")
            self.current = nil
            self.onState?(.stopped)
        }
    }

    // MARK: - Private

    private func dial() {
        guard !stopped else { return }
        onState?(attempt == 0 ? .connecting : .reconnecting(attempt: attempt))

        current?.close(reason: "user") // defensive: never leave a prior session running
        let session = makeSession()
        current = session
        onSession?(session) // caller wires media callbacks first…

        // …then we own the lifecycle callbacks. Capture `session` WEAKLY so a retired
        // session (still referenced by its own callbacks) can deallocate — otherwise
        // every dropped connection leaks a Session + transport + parser buffer.
        session.onPhaseChange = { [weak self, weak session] phase in
            guard let session else { return }
            self?.queue.async { self?.handlePhase(phase, of: session) }
        }
        session.onClosed = { [weak self, weak session] reason in
            guard let session else { return }
            self?.queue.async { self?.handleClosed(reason, of: session) }
        }
        session.start()
    }

    private func handlePhase(_ phase: SessionPhase, of session: Session) {
        guard session === current, !stopped else { return }
        if case .streaming = phase {
            attempt = 0
            onState?(.streaming)
        }
    }

    private func handleClosed(_ reason: String?, of session: Session) {
        guard session === current, !stopped else { return }
        current = nil

        if let reason, Self.fatalReasons.contains(reason) {
            coreLog.notice("reconnector: fatal close (\(reason, privacy: .public)) — not reconnecting")
            onState?(.failed(reason))
            return
        }

        attempt += 1
        let idx = min(attempt - 1, SessionConstants.reconnectBackoff.count - 1)
        let base = min(SessionConstants.reconnectBackoff[idx], SessionConstants.reconnectBackoffCap)
        let delay = base + base * 0.2 * jitterFraction(attempt)
        coreLog.notice("reconnector: attempt \(self.attempt) in \(String(format: "%.2f", delay))s (reason=\(reason ?? "nil", privacy: .public))")
        onState?(.reconnecting(attempt: attempt))
        let gen = generation
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == gen, !self.stopped else { return }
            self.dial()
        }
    }

    /// Deterministic pseudo-jitter (Math.random / Date are unavailable in some contexts);
    /// vary by attempt so retries don't synchronize.
    private func jitterFraction(_ n: Int) -> Double {
        Double((n &* 2_654_435_761) % 1000) / 1000.0
    }
}
