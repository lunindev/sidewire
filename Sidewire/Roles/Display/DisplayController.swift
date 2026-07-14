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
    /// Bounds the enterImmersive retry loop when the window is still opening (menu-bar-only).
    private var immersiveRetries = 0

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
    @Published var sourceName: String?
    @Published var presentedFps: Double = 0
    @Published var streamResolution = ""

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
        // A Thunderbolt cable plugged/unplugged while idle changes the "tb" TXT record we
        // advertise; re-arm the listener to readvertise. Never churn during an active session
        // (the accepted connection is unaffected, but the refresh isn't worth the noise).
        interfaceMonitor.onThunderboltIPChanged = { [weak self] _ in
            guard let self, self.session == nil else { return }
            Log.display.info("Thunderbolt interface changed → re-advertising listener TXT")
            self.restartListener()
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

        // Esc exits the immersive fullscreen (the InputCapture monitor deliberately
        // does NOT forward Esc to the Source, so this never leaks into the stream).
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.exitImmersive()
                return nil
            }
            return event
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
        session?.close(reason: "user")
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
        inputCapture.isEnabled = false
        stopVideoWatchdog()
        stopFpsCounter()
        powerAssertion.release()
        exitImmersive()
        isConnected = false
        isListening = false
        videoStalled = false
        statusText = String(localized: "Stopped")
        Log.event(.display, "stopped")
    }

    // MARK: - Private

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
        session?.close(reason: SessionConstants.supersededReason)

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
        // Identity-guard every queue-hopped callback so a superseded session can't
        // drive state that now belongs to a newer one.
        session.onPhaseChange = { [weak self, weak session] phase in
            Task { @MainActor in
                guard let self, self.session === session else { return }
                self.applyPhase(phase)
            }
        }
        session.onReady = { [weak self, weak session] config in
            Task { @MainActor in
                guard let self, self.session === session else { return }
                self.startPresenting(config: config)
            }
        }
        session.onVideoFrame = { [weak self, weak session] nal, isKey, ltrToken, ptsNanos in
            Task { @MainActor in
                guard let self, self.session === session else { return }
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
                guard let self, self.session === session else { return }
                self.handleClosed(reason)
            }
        }
        // Out-of-band cursor feed: the Source reports where its pointer is over the streamed
        // display; warp THIS Mac's native cursor there so the pointer tracks at network latency
        // instead of the video's decode lag (config.showsCursor stays false on the Source).
        session.onCursor = { [weak self, weak session] nx, ny in
            Task { @MainActor in
                guard let self, self.session === session else { return }
                self.warpCursor(nx: nx, ny: ny)
            }
        }
        // Heartbeat liveness: a PONG round-trip means the control link is alive even when no
        // video is flowing (static source screen). The no-frame watchdog uses this to avoid
        // treating a legitimately still screen as a stall.
        session.onRTT = { [weak self, weak session] _ in
            Task { @MainActor in
                guard let self, self.session === session else { return }
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
        inputCapture.isEnabled = true
        // The Source's cursor feed drives THIS Mac's native pointer (see warpCursor). Balance any
        // stray system hide once on connect so the pointer is guaranteed visible for the feed. A
        // single show (not a hide/unhide pair) can't leave the counter unbalanced.
        CGDisplayShowCursor(CGMainDisplayID())
        // D2 — hold the no-display-sleep assertion for the life of the connection.
        if AppSettings.shared.keepAwakeWhileConnected {
            powerAssertion.acquire(reason: "Sidewire is showing another Mac's screen")
        }
        enterImmersive()
        startFpsCounter()
        hasFirstFrame = false
        immersiveRetries = 0
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
                session?.close(reason: SessionConstants.noVideoReason)
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
            session?.close(reason: SessionConstants.noFrameReason)
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
        inputCapture.isEnabled = false
        powerAssertion.release() // D2 — connection ended; let the screen sleep again
        stopVideoWatchdog()
        stopFpsCounter()
        decoder?.invalidate()
        decoder = nil
        presenter.flush()
        presenter.videoSize = .zero
        exitImmersive()
        statusText = reason.map { CloseReasonText.display($0) } ?? String(localized: "Waiting for a Source…")
        session = nil
    }

    /// Warp this Mac's native cursor to where the Source's pointer is over the streamed display.
    /// `nx`/`ny` are normalized 0..1, TOP-LEFT origin — the exact inverse of
    /// `InputCapture.normalizedLocation`. Only runs while connected with a mounted window.
    private func warpCursor(nx: Float, ny: Float) {
        guard isConnected, let window = presenter.window else { return } // ignore stray/late callbacks
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

    /// Focus + fullscreen the video window and enable mouse-moved capture. Without
    /// acceptsMouseMovedEvents the NSEvent monitor never sees pointer movement, so the
    /// remote cursor wouldn't move (the reason mouse control appeared dead).
    private func enterImmersive() {
        guard let window = presenter.window else {
            // The window may still be opening (menu-bar-only just asked SwiftUI to open it).
            // Nudge it and retry briefly rather than give up, so the stream isn't invisible.
            if immersiveRetries < 20 {
                immersiveRetries += 1
                MainWindowOpener.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    Task { @MainActor in
                        guard let self, self.isConnected else { return }
                        self.enterImmersive()
                    }
                }
            } else {
                Log.media.notice("enterImmersive: no window after retries — video will appear once a window mounts")
            }
            return
        }
        immersiveRetries = 0
        NSApp.activate(ignoringOtherApps: true)
        window.acceptsMouseMovedEvents = true
        window.makeKeyAndOrderFront(nil)
        if !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        // The native cursor is actively driven by the Source's out-of-band cursor feed (warpCursor);
        // its visibility is balanced once on connect via CGDisplayShowCursor in startPresenting.
    }

    private func exitImmersive() {
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
