import Foundation
import AppKit
import SidewireProtocol
import SidewireCore

/// Display role: listens for a Source, decodes and presents video, and forwards
/// keyboard/mouse. @MainActor for SwiftUI observation and safe AppKit access.
@MainActor
final class DisplayController: ObservableObject {
    let presenter = VideoPresenterView(frame: .zero)
    /// The PIN a Source must enter to connect (shown on this Display). Persistent across
    /// launches; rotate on demand with `rotatePIN()`.
    @Published private(set) var pairingPIN = Pairing.localPIN

    private let listener = TCPListener(serviceName: DeviceIdentity.deviceName)
    /// Bounds online PIN guessing across successive pairing attempts (docs/05). One per Display;
    /// in-memory, so a relaunch clears any lockout.
    private let rateLimiter = PairingRateLimiter()
    private let inputCapture = InputCapture()
    private let interfaceMonitor = InterfaceMonitor()
    /// D2 — keeps this Mac's screen awake while a session is connected (gated by the setting).
    private let powerAssertion = PowerAssertion()
    private var decoder: VideoDecoder?
    private var session: Session?
    private var escMonitor: Any?
    private var wakeObserver: Any?
    /// Window/app-state observers backing `updateGrab()`. Re-armed whenever the presenter moves
    /// to a new window; split by notification center so each is unregistered from its own.
    private var windowObservers: [Any] = []
    private var workspaceObservers: [Any] = []
    /// Set when the user explicitly handed the pointer back (Esc / the control bar button) while
    /// the window still satisfies every grab condition. Cleared by a click on the video. Without
    /// this latch the grab would immediately re-arm itself and Esc would do nothing.
    private var userReleasedInput = false

    private var firstVideoLogged = false
    private var firstDecodedLogged = false
    /// The capture PTS (nanoseconds, source's monotonic epoch) of the most recent VIDEO frame,
    /// parsed from the wire subheader. Frames still render on arrival — this is exposed for the
    /// stats HUD and a future receiver-side jitter buffer. 0 until the first frame / when absent.
    private(set) var lastFramePTSNanos: UInt64 = 0

    // Receiver no-frame watchdog + decoder recovery ladder.
    private var videoWatchdog: Timer?
    private var lastPresentedNanos: UInt64 = 0
    private var streamStartNanos: UInt64 = 0
    private var hasFirstFrame = false
    private var decodeErrorStrikes = 0
    private var lastIDRRequestNanos: UInt64 = 0
    private var streamCodec: VideoCodec = .hevc
    /// Last time a heartbeat PONG landed (updated on the main actor via onRTT). PONGs flow
    /// ~2 Hz independent of video, so this is a video-independent "is the link alive" signal.
    private var lastHeartbeatNanos: UInt64 = 0

    @Published var statusText = String(localized: "Idle")
    @Published var isListening = false
    @Published var isConnected = false
    @Published var videoStalled = false
    /// True while this Mac's pointer and keyboard belong to the remote Mac: local input is
    /// forwarded and the Source's cursor feed drives the native pointer (`warpCursor`).
    ///
    /// This is the single gate for both. It requires the video window to actually be fullscreen,
    /// key, unminiaturized and on the active Space — because the cursor feed pins the pointer
    /// into the video rect, and in any lesser window state that pins it inside a *frame the user
    /// needs to escape from*: the pointer gets warped back on every move, so the window controls,
    /// the menu bar and the Dock all become unreachable. Requiring fullscreen makes that trap
    /// structurally impossible rather than merely unlikely.
    @Published private(set) var isGrabbed = false

    /// True when the stream is live and the window is immersive, but the user handed input back —
    /// so a click on the video would take control. Deliberately narrower than `!isGrabbed`: a
    /// windowed stream never grabs, and telling the user to click there would be a lie.
    @Published private(set) var canTakeControlByClicking = false
    @Published var sourceName: String?
    @Published var presentedFps: Double = 0
    @Published var streamResolution = ""

    /// This Mac's reachable IPv4 addresses (Wi-Fi / Ethernet / Thunderbolt), shown on the waiting
    /// screen so the other Mac's Connect-by-IP field is easy to type. Refreshed as links change.
    @Published var localAddresses: [LocalAddress] = []
    /// The port the listener actually bound. Surfaced with the addresses only when it isn't the
    /// well-known default — the port-ladder fallback can land elsewhere, and a manual connect then
    /// needs "IP:port".
    @Published var listeningPort: UInt16?

    private var presentedFrameCount = 0
    private var fpsTimer: Timer?

    init() {
        // NSEvent local monitors deliver on the main thread, so we're already on the
        // main actor here; assumeIsolated satisfies isolation without an async hop that
        // would add latency to the input hot path.
        inputCapture.onInputEvent = { [weak self] rec in
            MainActor.assumeIsolated { self?.session?.sendInput(rec) }
        }
        // So captured coordinates map into the aspect-fit video rect, not the whole view.
        inputCapture.presenter = presenter
        // AppKit calls viewDidMoveToWindow on the main thread; assumeIsolated keeps the window
        // hand-off synchronous so the grab can never be armed against a stale window.
        presenter.onWindowChange = { [weak self] window in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rearmWindowObservers(for: window)
                // The window may only now have mounted (menu-bar-only, or a reopen after ⌘W),
                // which is the deterministic moment to take the screen.
                if window != nil, self.isConnected { self.enterImmersive() }
            }
        }
        // Click-to-grab: the counterpart to Esc. Only re-arms if the window still qualifies —
        // clicking a windowed stream deliberately does nothing.
        presenter.onClick = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.userReleasedInput else { return }
                self.userReleasedInput = false
                self.updateGrab()
            }
        }
    }

    func start() {
        listener.onState = { [weak self] state in
            Task { @MainActor in
                self?.isListening = state.hasPrefix("listening")
                // Raw TCPListener state ("listening on port N", "listener error: …", "failed: …")
                // is a diagnostic readout, deliberately left unlocalized (F1) — mapping it to
                // human copy is backlog C2, not this localization pass.
                self?.statusText = state
            }
        }
        listener.onConnection = { [weak self] transport in
            Task { @MainActor in self?.accept(transport) }
        }
        listener.onReady = { [weak self] port in
            Task { @MainActor in self?.listeningPort = port }
        }
        // A Thunderbolt cable plugged/unplugged while idle changes the "tb" TXT record we
        // advertise; re-arm the listener to readvertise. Never churn during an active session
        // (the accepted connection is unaffected, but the refresh isn't worth the noise).
        interfaceMonitor.onThunderboltIPChanged = { [weak self] _ in
            guard let self, self.session == nil else { return }
            Log.display.info("Thunderbolt interface changed → re-advertising listener TXT")
            self.restartListener()
        }
        interfaceMonitor.onAddressesChanged = { [weak self] addrs in
            Task { @MainActor in self?.localAddresses = addrs }
        }
        interfaceMonitor.start()

        inputCapture.start()
        startListener()
        statusText = String(localized: "Listening…")

        // The listener socket can die silently across sleep with no `.failed` state, so re-arm
        // on wake (mirrors the Source's wake handling). Harmless to an already-accepted session.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                Log.display.notice("woke from sleep → re-arming listener")
                self.restartListener()
            }
        }

        // Esc hands the pointer and keyboard back to this Mac. It deliberately does NOT leave
        // fullscreen or close the session: releasing while still fullscreen is what lets the user
        // reach the menu bar and the control bar at all. Gated on `isGrabbed` so Esc behaves
        // normally everywhere else in the app — unconditionally swallowing keyCode 53 broke Esc
        // on the waiting screen and in the app's own popovers. The InputCapture monitor never
        // forwards Esc, so this can't leak into the stream either.
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.isGrabbed else { return event }
            self.releaseInput()
            return nil
        }
    }

    /// Re-arm the listener with the current PSK + a fresh Thunderbolt TXT record. Used by the
    /// waiting-overlay Retry, on wake, and on a Thunderbolt interface change. Does not disturb
    /// an already-accepted session — only the passive accept socket is rebuilt.
    func restartListener() {
        listener.stop()
        startListener()
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    /// Generate a fresh pairing PIN. In protocol v2 the PIN is not baked into the transport
    /// (TLS uses this Mac's certificate identity, not a PIN-derived key), so rotating it only
    /// changes the code required to pair a NEW Source — no listener restart is needed, and any
    /// already-paired Source keeps working via the stored trust-store key.
    func rotatePIN() {
        pairingPIN = Pairing.rotateLocalPIN()
        Log.source.info("pairing PIN rotated (applies to future pairings)")
    }

    /// Start (or re-arm) the listener with this Mac's TLS identity, advertising its device id
    /// ("did", so a paired Source can enforce key pinning) and its Thunderbolt link-local IP
    /// ("tb", for a one-click cable connect) over Bonjour TXT.
    private func startListener() {
        var txt: [String: String] = ["did": DeviceIdentity.deviceId]
        if let tb = InterfaceMonitor.localThunderboltIP() { txt["tb"] = tb }
        listener.start(identity: LocalIdentity.shared, txt: txt)
    }

    func stop() {
        closeSession(reason: "user") // releases the grab first — see closeSession
        session = nil
        listener.stop()
        interfaceMonitor.stop()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        // Remove the Esc monitor, or after a role switch the orphaned closure keeps swallowing
        // Esc app-wide (it returns nil for keyCode 53 even once this controller is gone).
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }
        stopVideoWatchdog()
        stopFpsCounter()
        powerAssertion.release()
        // closeSession already did this on the connected path, but it no-ops with no session —
        // a teardown states its end state rather than inferring it.
        isConnected = false
        isListening = false
        videoStalled = false
        rearmWindowObservers(for: nil)
        inputCapture.stop() // removes the monitor; isEnabled alone would leave it registered
        exitFullscreenIfNeeded()
        statusText = String(localized: "Stopped")
        Log.event(.display, "stopped")
    }

    // MARK: - Private

    /// Close the current session, ALWAYS releasing the input grab first. Every close goes through
    /// here, because the ordering is the whole point and getting it wrong is silent:
    /// `releaseHeldInput()` sends its keyUps/mouseUps *through this session*, while `Session.close`
    /// sets `closed` before it fires `onClosed` — so releasing afterwards drops them all and strands
    /// whatever the user was holding as physically down on the remote Mac. Those are posted at the
    /// HID event tap, so they outlive the session and keep auto-repeating there, and nothing on the
    /// Source side can undo them: the Display is the only end that tracks held input.
    /// `sendInput` and `close` share one serial queue, so releasing first provably drains ahead of
    /// the close.
    private func closeSession(reason: String) {
        guard session != nil else { return }
        isConnected = false
        updateGrab()
        session?.close(reason: reason)
    }

    private func accept(_ transport: TCPTransport) {
        Log.event(.display, "accepting incoming connection")
        // Menu-bar-only: with the main window closed, there's no view to present into, so video
        // would decode into a void and input capture would arm invisibly. Surface the window
        // now (enterImmersive retries until it mounts).
        if presenter.window == nil {
            Log.display.notice("accepting with no presenter window (menu-bar-only) → opening main window")
            MainWindowOpener.show()
        }

        // Newest connection wins (Phase 0). Phase 1 adds proper multi-peer/reconnect logic.
        // Via closeSession so a supersede mid-gesture releases what the outgoing session was
        // holding — the old session's onClosed can never do it, since `self.session` is reassigned
        // below before that callback's main-actor hop lands, so its identity guard rejects it.
        closeSession(reason: SessionConstants.supersededReason)

        let snapshot = currentDisplayInfo()
        let hello = DeviceIdentity.makeHello(role: .display, sessionId: UUID().uuidString)
        let session = Session(transport: transport, role: .display, localHello: hello)
        // Pairing: a first-time Source must complete the CPace PAKE against the PIN shown here;
        // a Source we've already pinned skips it (Session checks the trust store).
        session.pairingConfig = PairingConfig(pin: pairingPIN, trustStore: KeychainTrustStore.shared,
                                              rateLimiter: rateLimiter)
        self.session = session
        firstVideoLogged = false
        firstDecodedLogged = false

        session.provideDisplayInfo = { snapshot }
        session.onPaired = { peer in
            Task { @MainActor in
                Log.display.info("paired with Source \(peer.deviceId)")
                NotificationCenter.default.post(name: .sidewirePairedPeersChanged, object: nil)
            }
        }
        // Identity-guard every queue-hopped callback so a superseded session can't drive state
        // that now belongs to a newer one. `let session` is load-bearing, not decoration: these
        // fire after a main-actor hop, by which time both sides can be nil — and `nil === nil` is
        // TRUE in Swift, so without the unwrap the guard fails open and a dead session's callback
        // runs against the live controller.
        session.onPhaseChange = { [weak self, weak session] phase in
            Task { @MainActor in
                guard let self, let session, self.session === session else { return }
                self.applyPhase(phase)
            }
        }
        session.onReady = { [weak self, weak session] config in
            Task { @MainActor in
                guard let self, let session, self.session === session else { return }
                self.startPresenting(config: config)
            }
        }
        session.onVideoFrame = { [weak self, weak session] nal, isKey, ltrToken, ptsNanos in
            Task { @MainActor in
                guard let self, let session, self.session === session else { return }
                if !self.firstVideoLogged {
                    self.firstVideoLogged = true
                    Log.media.info("first VIDEO frame received (\(nal.count) bytes, key=\(isKey), pts=\(ptsNanos)ns)")
                }
                _ = ltrToken // reserved for the future lossy-transport LTR/NACK path
                // Expose the source's capture PTS (render is still on-arrival — no jitter buffer
                // yet; this is here for the stats HUD and a future receiver-side buffer).
                self.lastFramePTSNanos = ptsNanos
                self.decoder?.decode(nalData: nal, isKeyframe: isKey)
            }
        }
        session.onClosed = { [weak self, weak session] reason in
            Task { @MainActor in
                guard let self, let session, self.session === session else { return }
                self.handleClosed(reason)
            }
        }
        // Out-of-band cursor feed: the Source reports where its pointer is over the streamed
        // display; warp THIS Mac's native cursor there so the pointer tracks at network latency
        // instead of the video's decode lag (config.showsCursor stays false on the Source).
        session.onCursor = { [weak self, weak session] nx, ny in
            Task { @MainActor in
                guard let self, let session, self.session === session else { return }
                self.warpCursor(nx: nx, ny: ny)
            }
        }
        // Heartbeat liveness: a PONG round-trip means the control link is alive even when no
        // video is flowing (static source screen). The no-frame watchdog uses this to avoid
        // treating a legitimately still screen as a stall.
        session.onRTT = { [weak self, weak session] _ in
            Task { @MainActor in
                guard let self, let session, self.session === session else { return }
                self.lastHeartbeatNanos = DispatchTime.now().uptimeNanoseconds
            }
        }

        session.start()
    }

    private func applyPhase(_ phase: SessionPhase) {
        switch phase {
        case .connecting: statusText = String(localized: "Connecting…"); Log.event(.display, "phase: connecting")
        case .handshaking: statusText = String(localized: "Setting up…"); Log.event(.display, "phase: handshaking")
        case .streaming: isConnected = true; statusText = String(localized: "Connected"); Log.event(.display, "phase: streaming")
        case .closed(let reason):
            statusText = reason.map { CloseReasonText.display($0) } ?? String(localized: "Disconnected")
            Log.event(.display, "phase: closed (\(reason ?? "nil"))")
        }
    }

    private func startPresenting(config: Config) {
        streamCodec = VideoCodec(rawValue: config.codec) ?? .hevc
        makeDecoder()
        presenter.flush()
        isConnected = true
        videoStalled = false
        sourceName = session?.peerName
        statusText = String(localized: "Connected")
        // Technical readout (dimensions/fps/codec) — numbers and symbols only, nothing to
        // translate. Deliberately NOT run through String(localized:) (F1).
        streamResolution = "\(config.width)×\(config.height) @\(config.fps) · \(config.codec.uppercased())"
        presenter.videoSize = CGSize(width: config.width, height: config.height)
        // A fresh session starts owning the pointer again, whatever the previous one ended on.
        userReleasedInput = false
        // D2 — hold the no-display-sleep assertion for the life of the connection.
        if AppSettings.shared.keepAwakeWhileConnected {
            powerAssertion.acquire(reason: "Sidewire is showing another Mac's screen")
        }
        enterImmersive() // arms the grab via the window observers
        startFpsCounter()
        hasFirstFrame = false
        let now = DispatchTime.now().uptimeNanoseconds
        lastPresentedNanos = now
        streamStartNanos = now
        lastHeartbeatNanos = now // assume alive at stream start; onRTT keeps it fresh
        startVideoWatchdog()
        // Ask for a fresh keyframe so we start clean.
        session?.requestIDR()
        Log.event(.media, "presenting started \(config.width)x\(config.height)@\(config.fps) codec=\(config.codec)")
    }

    private func makeDecoder() {
        let decoder = VideoDecoder(codec: streamCodec)
        self.decoder = decoder
        decoder.onDecodedFrame = { [weak self] sampleBuffer in
            Task { @MainActor in
                guard let self else { return }
                self.lastPresentedNanos = DispatchTime.now().uptimeNanoseconds
                self.hasFirstFrame = true
                self.presentedFrameCount += 1
                self.decodeErrorStrikes = 0
                if self.videoStalled { self.videoStalled = false }
                if !self.firstDecodedLogged {
                    self.firstDecodedLogged = true
                    Log.media.info("first frame DECODED → presenting")
                }
                self.presenter.enqueue(sampleBuffer)
            }
        }
        decoder.onDecodeError = { [weak self] status in
            Task { @MainActor in self?.handleDecodeError(status) }
        }
    }

    // MARK: - Recovery

    /// VideoToolbox recovery ladder: request an IDR (throttled) on any decode error, and
    /// after repeated errors rebuild the decoder so the next keyframe fully re-primes it.
    private func handleDecodeError(_ status: OSStatus) {
        decodeErrorStrikes += 1
        Log.media.notice("decode error \(status) (strike \(self.decodeErrorStrikes))")
        let now = DispatchTime.now().uptimeNanoseconds
        if Double(now &- lastIDRRequestNanos) / 1_000_000 > 300 {
            lastIDRRequestNanos = now
            session?.requestIDR()
        }
        if decodeErrorStrikes >= SessionConstants.decoderRebuildLimit {
            decodeErrorStrikes = 0
            Log.media.notice("rebuilding decoder after repeated errors")
            decoder?.invalidate()
            makeDecoder()
            session?.requestIDR()
        }
    }

    private func startFpsCounter() {
        presentedFrameCount = 0
        fpsTimer?.invalidate()
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.presentedFps = Double(self.presentedFrameCount)
                self.presentedFrameCount = 0
            }
        }
    }

    private func stopFpsCounter() {
        fpsTimer?.invalidate(); fpsTimer = nil
        presentedFps = 0
    }

    private func startVideoWatchdog() {
        stopVideoWatchdog()
        videoWatchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.videoWatchdogTick() }
        }
    }

    private func stopVideoWatchdog() {
        videoWatchdog?.invalidate()
        videoWatchdog = nil
    }

    /// Watches for a wedged video pipeline. A legitimately static source screen produces no
    /// frames yet the control-plane heartbeat keeps flowing, so we distinguish the two: while
    /// the heartbeat is alive, "no video" just means the screen is still — keep the last frame
    /// on screen (no "Reconnecting…" flash) and nudge for a keyframe. Only a genuinely silent
    /// link dims. The long teardown stays UNGATED as a last-resort rebuild for a rare silent
    /// decoder wedge (frames arriving but not decoding, with the heartbeat still healthy).
    private func videoWatchdogTick() {
        guard isConnected else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        // Before the first frame ever arrives, don't dim/teardown on the normal budget —
        // display creation + capture start + first keyframe legitimately takes a few
        // seconds. Only give up after a generous grace (the source's own gates/heartbeat
        // handle a truly broken source).
        guard hasFirstFrame else {
            let sinceStartMs = Double(now &- streamStartNanos) / 1_000_000
            if sinceStartMs > 12_000 {
                Log.media.notice("no first frame in \(Int(sinceStartMs))ms → tearing down for reconnect")
                closeSession(reason: SessionConstants.noVideoReason)
            }
            return
        }
        let idleMs = Double(now &- lastPresentedNanos) / 1_000_000
        let heartbeatMs = Double(now &- lastHeartbeatNanos) / 1_000_000
        let linkAlive = lastHeartbeatNanos != 0 && heartbeatMs < SessionConstants.heartbeatTimeout * 1000

        if idleMs > SessionConstants.noFrameTeardown * 1000 {
            // Video wedged for a long time. If the link is alive this is a rare local decoder
            // wedge (not a disconnect); tear down either way so the Reconnector rebuilds.
            Log.media.notice("no decoded frame for \(Int(idleMs))ms (linkAlive=\(linkAlive)) → tearing down for reconnect")
            // linkAlive means the control link still works, so the releases genuinely reach the
            // Source — this is exactly the path where closing first would strand a held button.
            closeSession(reason: SessionConstants.noFrameReason)
        } else if idleMs > SessionConstants.noFrameDim * 1000 {
            if linkAlive {
                // Healthy link, just no new video → the source screen is static. Hold the last
                // frame (no scary overlay) and nudge for a fresh keyframe in case a keep-alive
                // was dropped.
                if videoStalled { videoStalled = false }
                if Double(now &- lastIDRRequestNanos) / 1_000_000 > 1000 {
                    lastIDRRequestNanos = now
                    session?.requestIDR()
                }
            } else if !videoStalled {
                videoStalled = true // link genuinely silent → real trouble, show reconnecting
            }
        }
    }

    private func handleClosed(_ reason: String?) {
        isConnected = false
        videoStalled = false
        sourceName = nil
        // Drops the grab: both input capture and the cursor warp disarm together.
        updateGrab()
        userReleasedInput = false
        powerAssertion.release() // D2 — connection ended; let the screen sleep again
        stopVideoWatchdog()
        stopFpsCounter()
        decoder?.invalidate()
        decoder = nil
        presenter.flush()
        presenter.videoSize = .zero
        // Deliberately does NOT leave fullscreen. Most closes are transient (wake, timeout) and the
        // Source redials within ~0.25s; toggling fullscreen here raced the reconnect's re-entry and
        // could leave the window windowed with a live session — the state that trapped the pointer.
        statusText = reason.map { CloseReasonText.display($0) } ?? String(localized: "Waiting for your main Mac…")
        session = nil
    }

    /// Warp this Mac's native cursor to where the Source's pointer is over the streamed display.
    /// `nx`/`ny` are normalized 0..1, TOP-LEFT origin — the exact inverse of
    /// `InputCapture.normalizedLocation`. Only ever runs while grabbed: outside the grab this
    /// pins the pointer inside the video rect on every move, which is a trap, not a feature.
    private func warpCursor(nx: Float, ny: Float) {
        guard isGrabbed, let window = presenter.window else { return } // ignore stray/late callbacks
        let rect = presenter.videoRect
        guard rect.width > 0, rect.height > 0 else { return }
        // 1) normalized (top-left) → presenter AppKit view coords (flip ny back to bottom-left).
        let viewX = rect.minX + CGFloat(nx) * rect.width
        let viewY = rect.minY + (1 - CGFloat(ny)) * rect.height
        // 2) view → window → AppKit global screen (bottom-left origin).
        let winPt = presenter.convert(CGPoint(x: viewX, y: viewY), to: nil)
        let screenPt = window.convertPoint(toScreen: winPt)
        // 3) AppKit global (bottom-left) → CG global (top-left) for the warp.
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let cgPt = CGPoint(x: screenPt.x, y: primaryH - screenPt.y)
        CGWarpMouseCursorPosition(cgPt)
        // CGWarp otherwise imposes a ~0.25s movement-suppression "stick"; re-associating cancels
        // it immediately so a continuous cursor feed stays smooth rather than stuttering.
        // (Takes boolean_t/Int32, not Bool — 1 == reconnect mouse to cursor.)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    // MARK: - Input grab

    /// Recompute whether the remote Mac owns this Mac's pointer and keyboard, and arm or disarm
    /// both pipes together. Every window/app/Space observer and every state change that can affect
    /// the answer routes through here — the grab is always derived, never inferred, because the
    /// two pipes drifting apart is exactly what trapped the pointer.
    private func updateGrab() {
        let qualifies = windowQualifiesForGrab
        let want = isConnected && !userReleasedInput && qualifies
        // Recomputed unconditionally — it changes on window state alone, even when the grab doesn't.
        canTakeControlByClicking = isConnected && !want && qualifies
        guard want != isGrabbed else { return }
        isGrabbed = want
        inputCapture.isEnabled = want
        // Without acceptsMouseMovedEvents the monitor never sees pointer movement, so the remote
        // cursor wouldn't move. It lives here (not in enterImmersive) so it re-arms correctly
        // when the view is remounted into a brand-new window after ⌘W.
        presenter.window?.acceptsMouseMovedEvents = want
        if want {
            // The pointer is about to become the remote pointer; guarantee it's visible for the
            // cursor feed. A single show (not a hide/unhide pair) can't unbalance the counter.
            CGDisplayShowCursor(CGMainDisplayID())
        } else {
            // Hand the pointer back: cancel any movement suppression left by the last warp, and
            // don't strand keys held at this instant as stuck-down on the remote Mac.
            CGAssociateMouseAndMouseCursorPosition(1)
            inputCapture.releaseHeldInput()
        }
        Log.event(.display, "input grab → \(want)")
    }

    /// Every window condition the grab depends on. Fullscreen is the load-bearing one: it is what
    /// guarantees there is no local window frame the warped pointer could be confined inside.
    private var windowQualifiesForGrab: Bool {
        guard let window = presenter.window else { return false }
        return window.styleMask.contains(.fullScreen)
            && window.isKeyWindow
            && !window.isMiniaturized
            && window.isOnActiveSpace
            && NSApp.isActive
    }

    /// Subscribe the grab to a window's lifecycle. Each of these can flip `windowQualifiesForGrab`,
    /// and before this the app observed none of them — it never knew its own window's state.
    private func rearmWindowObservers(for window: NSWindow?) {
        let nc = NotificationCenter.default
        windowObservers.forEach { nc.removeObserver($0) }
        windowObservers.removeAll()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()

        guard let window else {
            updateGrab() // no window ⇒ no grab
            return
        }
        let windowNames: [NSNotification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification,
        ]
        for name in windowNames {
            windowObservers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateGrab() }
            })
        }
        // App activation carries no window object, and a fullscreen window lives on its own Space:
        // ⌘-Tab and a Space switch must release just as surely as leaving fullscreen does.
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            windowObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateGrab() }
            })
        }
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateGrab() }
        })
        updateGrab()
    }

    /// Hand the pointer and keyboard back to this Mac's user without touching the session or the
    /// window. Esc and the control bar's release button both land here; clicking the video takes
    /// the grab back. Staying fullscreen on release is deliberate — that is what makes the control
    /// bar and the menu bar reachable at all.
    func releaseInput() {
        guard isGrabbed else { return }
        userReleasedInput = true
        updateGrab()
    }

    /// End this session but keep listening for the next one — the Display-role counterpart of the
    /// Source's Disconnect. Previously the only ways out of a live session from this side were ⌘Q
    /// and "Switch role" (which tears the whole role down).
    func disconnect() {
        guard session != nil else { return }
        Log.event(.display, "user disconnected")
        // The peer reads "user" as "the other Mac disconnected", which is true for it. Locally,
        // handleClosed(nil) restores "Waiting for your main Mac…" — we didn't lose the link, we're
        // listening again.
        closeSession(reason: "user")
        handleClosed(nil)
        exitFullscreenIfNeeded()
    }

    // MARK: - Window

    /// Take the screen for the stream. Idempotent: on a transient reconnect the window is already
    /// fullscreen, and re-activating would yank the user out of whatever Space they had moved to.
    /// The grab arms itself from the didEnterFullScreen / didBecomeKey observers.
    private func enterImmersive() {
        guard let window = presenter.window else { return } // onWindowChange calls back when it mounts
        guard !window.styleMask.contains(.fullScreen) else {
            updateGrab()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
    }

    /// Leave fullscreen. Only ever called for a real teardown (`stop()`) or an explicit user
    /// action — never on a transient close, which would thrash the window on every reconnect blip.
    private func exitFullscreenIfNeeded() {
        guard let window = presenter.window, window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    /// Snapshot the real panel hosting the video window (falling back to the main screen if
    /// there's no window yet, e.g. menu-bar-only). Uses the actual refresh rate and backing
    /// scale so the Source sizes and paces the stream correctly. This is a one-time snapshot at
    /// accept time; mid-session monitor changes (DISPLAY_INFO resend) are Phase 7 work.
    private func currentDisplayInfo() -> DisplayInfo {
        guard let screen = presenter.window?.screen ?? NSScreen.main else {
            return DisplayInfo(width: 2560, height: 1600, scaleFactor: 2.0, refreshRate: 60, name: "Display")
        }
        let scale = screen.backingScaleFactor
        let refresh = screen.maximumFramesPerSecond
        return DisplayInfo(width: Int(screen.frame.width * scale),
                           height: Int(screen.frame.height * scale),
                           scaleFactor: Double(scale),
                           refreshRate: refresh > 0 ? Double(refresh) : 60,
                           name: screen.localizedName)
    }
}
