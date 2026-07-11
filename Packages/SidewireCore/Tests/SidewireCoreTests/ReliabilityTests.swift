import XCTest
@testable import SidewireCore
import SidewireProtocol

/// A transport that becomes ready but never delivers a frame — models a peer that
/// vanished without a TCP RST (half-open), so only the app heartbeat can detect it.
private final class SilentTransport: Transport, @unchecked Sendable {
    var onFrame: ((Frame) -> Void)?
    var onState: ((TransportState) -> Void)?
    func start() { onState?(.ready) }
    func cancel() { onState?(.cancelled) }
    func send(rawType: UInt8, flags: UInt8, seq: UInt32, payload: Data) { /* swallowed */ }
}

final class ReliabilityTests: XCTestCase {

    private func caps() -> Capabilities {
        Capabilities(videoCodecs: ["hevc"], maxWidth: 3840, maxHeight: 2160, maxFps: 60,
                     ltr: false, audio: false, hdr: false)
    }

    /// The heartbeat watchdog must declare a silent peer dead (reason "timeout") within
    /// ~HEARTBEAT_TIMEOUT — this is the fix for the cable-pull hang / half-open TCP.
    func testHeartbeatTimeoutClosesSilentPeer() {
        let transport = SilentTransport()
        let hello = Hello(role: .source, deviceId: "src", deviceName: "S",
                          sessionId: "s", capabilities: caps())
        let session = Session(transport: transport, role: .source, localHello: hello)

        let closed = expectation(description: "closed on heartbeat timeout")
        session.onClosed = { reason in
            XCTAssertEqual(reason, "timeout")
            closed.fulfill()
        }
        session.start()
        // heartbeatTimeout is 2.5s; allow margin.
        wait(for: [closed], timeout: 6.0)
    }

    /// The Reconnector must re-establish the session after a non-user drop, over the
    /// real TCP stack — this is auto-reconnect working in practice.
    func testReconnectAfterDrop() {
        let listener = TCPListener(serviceName: "sidewire-test")
        let portReady = expectation(description: "listener bound")
        var boundPort: UInt16 = 0
        listener.onReady = { p in boundPort = p; portReady.fulfill() }

        final class Box: @unchecked Sendable {
            var session: Session?
            var connections = 0
        }
        let box = Box()

        listener.onConnection = { [caps] transport in
            box.connections += 1
            let hello = Hello(role: .display, deviceId: "d", deviceName: "D",
                              sessionId: "s", capabilities: caps())
            let s = Session(transport: transport, role: .display, localHello: hello)
            s.provideDisplayInfo = {
                DisplayInfo(width: 1920, height: 1200, scaleFactor: 2, refreshRate: 60, name: "t")
            }
            box.session = s
            s.start()
        }
        listener.start(port: 0, advertise: false)
        wait(for: [portReady], timeout: 5)

        let sourceHello = Hello(role: .source, deviceId: "src", deviceName: "S",
                                sessionId: "s", capabilities: caps())
        let reconnector = Reconnector(makeSession: {
            Session(transport: TCPTransport(host: "127.0.0.1", port: boundPort),
                    role: .source, localHello: sourceHello)
        })

        let firstStreaming = expectation(description: "first streaming")
        let secondStreaming = expectation(description: "streaming again after drop")
        let counter = NSLock()
        var streamingCount = 0
        var dropped = false

        reconnector.onState = { state in
            guard case .streaming = state else { return }
            counter.lock(); streamingCount += 1; let n = streamingCount; counter.unlock()
            if n == 1 {
                firstStreaming.fulfill()
                if !dropped { dropped = true; box.session?.close(reason: "drop") } // simulate a drop
            } else if n == 2 {
                secondStreaming.fulfill()
            }
        }
        reconnector.start()

        wait(for: [firstStreaming], timeout: 6)
        wait(for: [secondStreaming], timeout: 6)
        XCTAssertGreaterThanOrEqual(box.connections, 2)

        reconnector.stop()
        listener.stop()
    }
}
