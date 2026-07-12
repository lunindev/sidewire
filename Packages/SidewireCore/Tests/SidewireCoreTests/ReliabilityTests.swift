import XCTest
@testable import SidewireCore
import SidewireProtocol

/// A transport that becomes ready but never delivers a frame — models a peer that
/// vanished without a TCP RST (half-open), so only the app heartbeat can detect it.
private final class SilentTransport: Transport, @unchecked Sendable {
    var onFrame: ((Frame) -> Void)?
    var onState: ((TransportState) -> Void)?
    var onInterface: ((String) -> Void)?
    var onSecurity: ((TLSPeerInfo) -> Void)?
    func start() { onState?(.ready) }
    func cancel() { onState?(.cancelled) }
    func send(rawType: UInt8, flags: UInt8, seq: UInt32, payload: Data) { /* swallowed */ }
}

/// A transport that fails immediately with a fixed reason — models a fatal handshake
/// outcome (e.g. a wrong-PIN "auth" failure surfaced by TCPTransport).
private final class FailingTransport: Transport, @unchecked Sendable {
    var onFrame: ((Frame) -> Void)?
    var onState: ((TransportState) -> Void)?
    var onInterface: ((String) -> Void)?
    var onSecurity: ((TLSPeerInfo) -> Void)?
    private let reason: String
    init(reason: String) { self.reason = reason }
    func start() { onState?(.failed(reason)) }
    func cancel() { onState?(.cancelled) }
    func send(rawType: UInt8, flags: UInt8, seq: UInt32, payload: Data) {}
}

final class ReliabilityTests: XCTestCase {

    private var bag: IdentityBag!
    override func setUp() { super.setUp(); bag = IdentityBag() }
    override func tearDown() { bag.destroyAll(); super.tearDown() }

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

    /// A wrong-PIN "auth" failure is fatal: the Reconnector must surface it and NOT re-dial
    /// (re-dialing with the same wrong PSK could only fail again → the silent reconnect loop).
    func testReconnectorDoesNotRetryOnAuthFailure() {
        let hello = Hello(role: .source, deviceId: "src", deviceName: "S",
                          sessionId: "s", capabilities: caps())
        let lock = NSLock()
        var makeCount = 0
        let reconnector = Reconnector(makeSession: {
            lock.lock(); makeCount += 1; lock.unlock()
            return Session(transport: FailingTransport(reason: "auth"),
                           role: .source, localHello: hello)
        })

        let failed = expectation(description: "link reports auth failure")
        failed.assertForOverFulfill = false
        reconnector.onState = { state in
            if case .failed(let reason) = state {
                XCTAssertEqual(reason, "auth")
                failed.fulfill()
            }
        }
        reconnector.start()
        wait(for: [failed], timeout: 5)

        // Give any (incorrect) backoff dial time to fire, then confirm we dialed exactly once.
        Thread.sleep(forTimeInterval: 1.0)
        lock.lock(); let count = makeCount; lock.unlock()
        XCTAssertEqual(count, 1, "auth is fatal → the Reconnector must not re-dial")
        reconnector.stop()
    }

    /// A "superseded" close (another Source displaced this one on the Display, newest-wins)
    /// is fatal: the ousted Reconnector must surface it and NOT re-dial, or two Sources would
    /// steal the Display from each other forever.
    func testReconnectorDoesNotRetryOnSuperseded() {
        let hello = Hello(role: .source, deviceId: "src", deviceName: "S",
                          sessionId: "s", capabilities: caps())
        let lock = NSLock()
        var makeCount = 0
        let reconnector = Reconnector(makeSession: {
            lock.lock(); makeCount += 1; lock.unlock()
            return Session(transport: FailingTransport(reason: SessionConstants.supersededReason),
                           role: .source, localHello: hello)
        })

        let failed = expectation(description: "link reports superseded")
        failed.assertForOverFulfill = false
        reconnector.onState = { state in
            if case .failed(let reason) = state {
                XCTAssertEqual(reason, SessionConstants.supersededReason)
                failed.fulfill()
            }
        }
        reconnector.start()
        wait(for: [failed], timeout: 5)

        // Give any (incorrect) backoff dial time to fire, then confirm we dialed exactly once.
        Thread.sleep(forTimeInterval: 1.0)
        lock.lock(); let count = makeCount; lock.unlock()
        XCTAssertEqual(count, 1, "superseded is fatal → the Reconnector must not re-dial")
        reconnector.stop()
    }

    /// A `.failed` listener must re-arm itself: after the OS drops the socket (modelled here
    /// by a forced port collision), the listener auto-restarts and eventually binds again.
    func testListenerAutoRestartsAfterFailure() throws {
        // Occupy an ephemeral port with a first listener, learn the port, then aim a second
        // listener at it: the second fails to bind, and its auto-restart must keep retrying.
        // Freeing the port (stopping the first) lets a later restart succeed.
        let id = try bag.make()
        let first = TCPListener(serviceName: "sidewire-test-occupier")
        let firstReady = expectation(description: "occupier bound")
        var port: UInt16 = 0
        first.onReady = { p in if port == 0 { port = p; firstReady.fulfill() } }
        first.start(port: 0, advertise: false, identity: id)
        wait(for: [firstReady], timeout: 5)

        let second = TCPListener(serviceName: "sidewire-test-restarter")
        let secondBound = expectation(description: "restarter eventually binds after the port frees")
        second.onReady = { _ in secondBound.fulfill() }
        // allowLocalEndpointReuse can let both share the port; if the second binds immediately
        // that's still a valid "it listens" outcome. Either way we must reach .ready.
        second.start(port: port, advertise: false, identity: id)
        // Free the port shortly after so a restart attempt (1s backoff) can succeed.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { first.stop() }

        wait(for: [secondBound], timeout: 8)
        second.stop()
    }

    /// The Reconnector must re-establish the session after a non-user drop, over the
    /// real TCP stack — this is auto-reconnect working in practice.
    func testReconnectAfterDrop() throws {
        let displayID = try bag.make(), sourceID = try bag.make()
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
        listener.start(port: 0, advertise: false, identity: displayID)
        wait(for: [portReady], timeout: 5)

        let sourceHello = Hello(role: .source, deviceId: "src", deviceName: "S",
                                sessionId: "s", capabilities: caps())
        let reconnector = Reconnector(makeSession: {
            Session(transport: TCPTransport(host: "127.0.0.1", port: boundPort, identity: sourceID),
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
