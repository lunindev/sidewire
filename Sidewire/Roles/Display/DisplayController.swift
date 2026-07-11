import Foundation
import AppKit
import SidewireProtocol
import SidewireCore

/// Display role: listens for a Source, decodes and presents video, and forwards
/// keyboard/mouse. @MainActor for SwiftUI observation and safe AppKit access.
@MainActor
final class DisplayController: ObservableObject {
    let presenter = VideoPresenterView(frame: .zero)

    private let listener = TCPListener(serviceName: DeviceIdentity.deviceName)
    private let inputCapture = InputCapture()
    private var decoder: VideoDecoder?
    private var session: Session?
    private var escMonitor: Any?

    private var firstVideoLogged = false
    private var firstDecodedLogged = false

    @Published var statusText = "Idle"
    @Published var isListening = false
    @Published var isConnected = false
    @Published var sourceName: String?

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
        listener.start()
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
        exitImmersive()
        isConnected = false
        isListening = false
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
        session.onVideoFrame = { [weak self, weak session] nal, isKey, _ in
            Task { @MainActor in
                guard let self, self.session === session else { return }
                if !self.firstVideoLogged {
                    self.firstVideoLogged = true
                    Log.media.info("first VIDEO frame received (\(nal.count) bytes, key=\(isKey))")
                }
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
        let decoder = VideoDecoder()
        self.decoder = decoder
        decoder.onDecodedFrame = { [weak self] sampleBuffer in
            Task { @MainActor in
                guard let self else { return }
                if !self.firstDecodedLogged {
                    self.firstDecodedLogged = true
                    Log.media.info("first frame DECODED → presenting")
                }
                self.presenter.enqueue(sampleBuffer)
            }
        }
        presenter.flush()
        isConnected = true
        sourceName = session?.peerName
        statusText = "Connected"
        inputCapture.isEnabled = true
        enterImmersive()
        // Ask for a fresh keyframe so we start clean.
        session?.requestIDR()
        Log.media.info("presenting started \(config.width)x\(config.height)@\(config.fps) codec=\(config.codec)")
    }

    private func handleClosed(_ reason: String?) {
        isConnected = false
        sourceName = nil
        inputCapture.isEnabled = false
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
    }

    private func exitImmersive() {
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
