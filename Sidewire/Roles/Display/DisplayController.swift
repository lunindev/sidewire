import Foundation
import AppKit
import SidewireProtocol
import SidewireCore

/// Display role: listens for a Source, decodes and presents video, and forwards
/// keyboard/mouse. @MainActor for SwiftUI observation and safe AppKit access.
@MainActor
final class DisplayController: ObservableObject {
    let presenter = VideoPresenterView(frame: .zero)
    /// The PIN a Source must enter to connect (shown on this Display).
    let pairingPIN = Pairing.localPIN

    private let listener = TCPListener(serviceName: DeviceIdentity.deviceName)
    private let inputCapture = InputCapture()
    private var decoder: VideoDecoder?
    private var session: Session?
    private var escMonitor: Any?

    private var firstVideoLogged = false
    private var firstDecodedLogged = false

    // Receiver no-frame watchdog + decoder recovery ladder.
    private var videoWatchdog: Timer?
    private var lastPresentedNanos: UInt64 = 0
    private var streamStartNanos: UInt64 = 0
    private var hasFirstFrame = false
    private var cursorHidden = false
    private var decodeErrorStrikes = 0
    private var lastIDRRequestNanos: UInt64 = 0

    @Published var statusText = "Idle"
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
    }

    func start() {
        listener.onState = { [weak self] state in
            Task { @MainActor in
                self?.isListening = state.hasPrefix("listening")
                self?.statusText = state
            }
        }
        listener.onConnection = { [weak self] transport in
            Task { @MainActor in self?.accept(transport) }
        }
        inputCapture.start()
        listener.start(psk: Pairing.credential(pin: pairingPIN))
        statusText = "Listening…"

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

    func stop() {
        session?.close(reason: "user")
        session = nil
        listener.stop()
        inputCapture.isEnabled = false
        stopVideoWatchdog()
        stopFpsCounter()
        exitImmersive()
        isConnected = false
        isListening = false
        videoStalled = false
        statusText = "Stopped"
    }

    // MARK: - Private

    private func accept(_ transport: TCPTransport) {
        // Newest connection wins (Phase 0). Phase 1 adds proper multi-peer/reconnect logic.
        session?.close(reason: "superseded")

        let snapshot = Self.currentDisplayInfo()
        let hello = DeviceIdentity.makeHello(role: .display, sessionId: UUID().uuidString)
        let session = Session(transport: transport, role: .display, localHello: hello)
        self.session = session
        firstVideoLogged = false
        firstDecodedLogged = false

        session.provideDisplayInfo = { snapshot }
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
        session.onVideoFrame = { [weak self, weak session] nal, isKey, ltrToken in
            Task { @MainActor in
                guard let self, self.session === session else { return }
                if !self.firstVideoLogged {
                    self.firstVideoLogged = true
                    Log.media.info("first VIDEO frame received (\(nal.count) bytes, key=\(isKey))")
                }
                _ = ltrToken // reserved for the future lossy-transport LTR/NACK path
                self.decoder?.decode(nalData: nal, isKeyframe: isKey)
            }
        }
        session.onClosed = { [weak self, weak session] reason in
            Task { @MainActor in
                guard let self, self.session === session else { return }
                self.handleClosed(reason)
            }
        }

        session.start()
    }

    private func applyPhase(_ phase: SessionPhase) {
        switch phase {
        case .connecting: statusText = "Connecting…"
        case .handshaking: statusText = "Setting up…"
        case .streaming: isConnected = true; statusText = "Connected"
        case .closed(let reason): statusText = reason.map { "Closed: \($0)" } ?? "Disconnected"
        }
    }

    private func startPresenting(config: Config) {
        makeDecoder()
        presenter.flush()
        isConnected = true
        videoStalled = false
        sourceName = session?.peerName
        statusText = "Connected"
        streamResolution = "\(config.width)×\(config.height) @\(config.fps) · \(config.codec.uppercased())"
        inputCapture.isEnabled = true
        enterImmersive()
        startFpsCounter()
        hasFirstFrame = false
        let now = DispatchTime.now().uptimeNanoseconds
        lastPresentedNanos = now
        streamStartNanos = now
        startVideoWatchdog()
        // Ask for a fresh keyframe so we start clean.
        session?.requestIDR()
        Log.media.info("presenting started \(config.width)x\(config.height)@\(config.fps) codec=\(config.codec)")
    }

    private func makeDecoder() {
        let decoder = VideoDecoder()
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

    /// If no decoded frame has been presented for a while (despite the source's keep-alive
    /// keyframes on a static screen), the video pipeline is wedged: dim + show reconnecting,
    /// then tear the session down so the Reconnector rebuilds everything.
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
                session?.close(reason: "no-video")
            }
            return
        }
        let idleMs = Double(now &- lastPresentedNanos) / 1_000_000
        if idleMs > SessionConstants.noFrameTeardown * 1000 {
            Log.media.notice("no decoded frame for \(Int(idleMs))ms → tearing down for reconnect")
            session?.close(reason: "no-frame")
        } else if idleMs > SessionConstants.noFrameDim * 1000 {
            if !videoStalled { videoStalled = true }
        }
    }

    private func handleClosed(_ reason: String?) {
        isConnected = false
        videoStalled = false
        sourceName = nil
        inputCapture.isEnabled = false
        stopVideoWatchdog()
        stopFpsCounter()
        decoder?.invalidate()
        decoder = nil
        presenter.flush()
        exitImmersive()
        statusText = reason.map { "Closed: \($0)" } ?? "Waiting for a Source…"
        session = nil
    }

    /// Focus + fullscreen the video window and enable mouse-moved capture. Without
    /// acceptsMouseMovedEvents the NSEvent monitor never sees pointer movement, so the
    /// remote cursor wouldn't move (the reason mouse control appeared dead).
    private func enterImmersive() {
        guard let window = presenter.window else {
            Log.media.notice("enterImmersive: presenter has no window yet")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        window.acceptsMouseMovedEvents = true
        window.makeKeyAndOrderFront(nil)
        if !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        // Hide the local cursor so only the source's cursor (baked into the video) shows.
        if !cursorHidden { NSCursor.hide(); cursorHidden = true }
    }

    private func exitImmersive() {
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
        guard let window = presenter.window, window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    private static func currentDisplayInfo() -> DisplayInfo {
        guard let screen = NSScreen.main else {
            return DisplayInfo(width: 2560, height: 1600, scaleFactor: 2.0, refreshRate: 60, name: "Display")
        }
        let scale = screen.backingScaleFactor
        return DisplayInfo(width: Int(screen.frame.width * scale),
                           height: Int(screen.frame.height * scale),
                           scaleFactor: Double(scale), refreshRate: 60,
                           name: screen.localizedName)
    }
}
