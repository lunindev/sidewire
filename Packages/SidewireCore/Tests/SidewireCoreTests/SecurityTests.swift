import XCTest
@testable import SidewireCore
import SidewireProtocol

/// End-to-end tests of the certificate-based TLS 1.3 + channel-bound PIN proof + trust store
/// over the REAL Network.framework stack on 127.0.0.1 (docs/05, docs/09 §D11). Throwaway P-256
/// identities are minted per test and their Keychain items removed in tearDown.
final class SecurityTests: XCTestCase {

    private var bag: IdentityBag!
    override func setUp() { super.setUp(); bag = IdentityBag() }
    override func tearDown() { bag.destroyAll(); super.tearDown() }

    /// Start a Display listener (ephemeral port, no Bonjour) that builds a display `Session` with
    /// the given pairing config for each accepted connection. `configure` can observe the
    /// per-connection display session. Returns the listener + bound port.
    /// Retains every accepted display session for the test's lifetime. Each `startDisplay` call
    /// gets a fresh retainer that the returned tuple keeps alive.
    private let retainer = SessionRetainer()

    @discardableResult
    private func startDisplay(identity: LocalIdentity, trust: any TrustStoring, pin: String,
                             rateLimiter: PairingRateLimiter? = nil,
                             configure: @escaping (Session, TapTransport) -> Void = { _, _ in }) -> (TCPListener, UInt16) {
        let listener = TCPListener(serviceName: "sec-test")
        let retainer = self.retainer
        final class PortBox: @unchecked Sendable { var port: UInt16 = 0 }
        let portBox = PortBox()
        let portReady = expectation(description: "bound")
        listener.onReady = { p in portBox.port = p; portReady.fulfill() }
        listener.onConnection = { transport in
            let tap = TapTransport(transport)
            let s = Session(transport: tap, role: .display,
                            localHello: testHello(role: .display, name: "D"))
            s.pairingConfig = PairingConfig(pin: pin, trustStore: trust, rateLimiter: rateLimiter)
            s.provideDisplayInfo = { DisplayInfo(width: 1920, height: 1200, scaleFactor: 2, refreshRate: 60, name: "t") }
            retainer.keep(s)
            configure(s, tap)
            s.start()
        }
        listener.start(port: 0, advertise: false, identity: identity)
        wait(for: [portReady], timeout: 5)
        return (listener, portBox.port)
    }

    private func makeSource(port: UInt16, identity: LocalIdentity, pin: String, trust: any TrustStoring,
                           expectedPeerDeviceId: String? = nil) -> (Session, TapTransport) {
        let tap = TapTransport(TCPTransport(host: "127.0.0.1", port: port, identity: identity,
                                            expectedPeerDeviceId: expectedPeerDeviceId))
        let s = Session(transport: tap, role: .source, localHello: testHello(role: .source, name: "S"))
        s.pairingConfig = PairingConfig(pin: pin, trustStore: trust)
        return (s, tap)
    }

    // MARK: - Happy path

    func testHappyPathPairsBothSidesAndStreams() throws {
        let displayID = try bag.make(), sourceID = try bag.make()
        let displayTrust = InMemoryTrustStore(), sourceTrust = InMemoryTrustStore()

        let displayReady = expectation(description: "display ready")
        let gotVideo = expectation(description: "encrypted video round-trip")
        let box = SessionBox()
        let (listener, port) = startDisplay(identity: displayID, trust: displayTrust, pin: "123456") { s, tap in
            box.session = s; box.tap = tap
            s.onReady = { _ in displayReady.fulfill() }
            s.onVideoFrame = { nal, _, _, _ in
                XCTAssertEqual(nal, Data([1, 2, 3])); gotVideo.fulfill()
            }
        }

        let (source, sourceTap) = makeSource(port: port, identity: sourceID, pin: "123456", trust: sourceTrust)
        let sourceReady = expectation(description: "source ready")
        source.onReady = { _ in sourceReady.fulfill() }
        source.start()

        wait(for: [sourceReady, displayReady], timeout: 15)

        // Both sides pinned the peer (by the peer's self-authenticating, cert-derived deviceId).
        XCTAssertNotNil(sourceTrust.pinned(for: displayID.deviceId), "source must pin the display")
        XCTAssertNotNil(displayTrust.pinned(for: sourceID.deviceId), "display must pin the source")
        XCTAssertEqual(sourceTrust.pinned(for: displayID.deviceId)?.spkiHash, displayID.spkiHash.hexString)

        // A proof WAS exchanged on this first-time pairing.
        XCTAssertGreaterThan(sourceTap.sentCount(of: .pairProof), 0)
        XCTAssertGreaterThan(sourceTap.sentCount(of: .pairAck), 0)

        source.sendVideo(Data([1, 2, 3]), keyframe: true)
        wait(for: [gotVideo], timeout: 5)
        source.close(reason: "user")
        listener.stop()
    }

    // MARK: - Wrong PIN

    func testWrongPINClosesWithAuthAndDoesNotPin() throws {
        let displayID = try bag.make(), sourceID = try bag.make()
        let displayTrust = InMemoryTrustStore(), sourceTrust = InMemoryTrustStore()

        let (listener, port) = startDisplay(identity: displayID, trust: displayTrust, pin: "111111")
        let (source, _) = makeSource(port: port, identity: sourceID, pin: "999999", trust: sourceTrust) // wrong

        let closed = expectation(description: "source closes")
        closed.assertForOverFulfill = false
        final class ReasonBox: @unchecked Sendable { var reason: String? }
        let rbox = ReasonBox()
        source.onReady = { _ in XCTFail("must not reach streaming with a wrong PIN") }
        source.onClosed = { r in rbox.reason = r; closed.fulfill() }
        source.start()

        wait(for: [closed], timeout: 15)
        XCTAssertEqual(rbox.reason, SessionConstants.authFailureReason, "wrong PIN must classify as auth")
        XCTAssertNil(sourceTrust.pinned(for: displayID.deviceId), "no pinning on a failed proof")
        XCTAssertNil(displayTrust.pinned(for: sourceID.deviceId), "no pinning on a failed proof")
        listener.stop()
    }

    // MARK: - Paired reconnect

    func testPairedReconnectSkipsProofEntirely() throws {
        let displayID = try bag.make(), sourceID = try bag.make()
        // Both sides already trust each other (a prior pairing).
        let displayTrust = InMemoryTrustStore(), sourceTrust = InMemoryTrustStore()
        sourceTrust.pin(pin(for: displayID, name: "D"))
        displayTrust.pin(pin(for: sourceID, name: "S"))

        let displayReady = expectation(description: "display ready")
        let box = SessionBox()
        let (listener, port) = startDisplay(identity: displayID, trust: displayTrust, pin: "123456") { s, tap in
            box.session = s; box.tap = tap
            s.onReady = { _ in displayReady.fulfill() }
        }
        let (source, sourceTap) = makeSource(port: port, identity: sourceID, pin: "123456", trust: sourceTrust)
        let sourceReady = expectation(description: "source ready")
        source.onReady = { _ in sourceReady.fulfill() }
        source.start()

        wait(for: [sourceReady, displayReady], timeout: 15)

        // The whole point: NO pairing messages crossed the wire in either direction.
        XCTAssertEqual(sourceTap.sentCount(of: .pairProof), 0)
        XCTAssertEqual(sourceTap.receivedCount(of: .pairProof), 0)
        XCTAssertEqual(sourceTap.sentCount(of: .pairAck), 0)
        XCTAssertEqual(box.tap?.sentCount(of: .pairProof), 0)
        XCTAssertEqual(box.tap?.receivedCount(of: .pairAck), 0)
        // And HELLO did flow (handshake reached streaming).
        XCTAssertGreaterThan(sourceTap.sentCount(of: .hello), 0)
        source.close(reason: "user")
        listener.stop()
    }

    /// Asymmetric pin state: the Source forgot the Display but the Display still trusts the
    /// Source (same keys). The Source must lead with a PIN proof and the paired Display must
    /// re-run the proof (not deadlock by eagerly sending HELLO) — healing back to a paired state.
    func testSourceForgotDisplayStillPairedRepairsCleanly() throws {
        let displayID = try bag.make(), sourceID = try bag.make()
        let displayTrust = InMemoryTrustStore(), sourceTrust = InMemoryTrustStore()
        displayTrust.pin(pin(for: sourceID, name: "S")) // Display remembers; Source's store is empty.

        let displayReady = expectation(description: "display ready")
        let (listener, port) = startDisplay(identity: displayID, trust: displayTrust, pin: "123456") { s, _ in
            s.onReady = { _ in displayReady.fulfill() }
        }
        // Source forgot ⇒ no expected peer id, so it re-pairs like a first-time connect.
        let (source, sourceTap) = makeSource(port: port, identity: sourceID, pin: "123456", trust: sourceTrust)
        let sourceReady = expectation(description: "source ready")
        source.onReady = { _ in sourceReady.fulfill() }
        source.start()

        wait(for: [sourceReady, displayReady], timeout: 15)
        // A fresh proof healed the asymmetry, and both sides are pinned again.
        XCTAssertGreaterThan(sourceTap.sentCount(of: .pairProof), 0, "the Source must re-prove")
        XCTAssertNotNil(sourceTrust.pinned(for: displayID.deviceId), "source re-pins the display")
        XCTAssertNotNil(displayTrust.pinned(for: sourceID.deviceId), "display keeps the source pinned")
        source.close(reason: "user")
        listener.stop()
    }

    // MARK: - Key change

    func testKeyChangeIsRejected() throws {
        // The Display presents identity D2, but the Source expects a previously-pinned D1.
        let realDisplay = try bag.make()
        let pinnedButGoneID = try bag.make() // the id the Source thinks it paired with
        let sourceID = try bag.make()
        let sourceTrust = InMemoryTrustStore()
        sourceTrust.pin(pin(for: pinnedButGoneID, name: "OldDisplay"))

        let (listener, port) = startDisplay(identity: realDisplay, trust: InMemoryTrustStore(), pin: "123456")

        // Source dials expecting the old (pinned) deviceId, but the live Display's key differs.
        let (source, sourceTap) = makeSource(port: port, identity: sourceID, pin: "123456",
                                             trust: sourceTrust, expectedPeerDeviceId: pinnedButGoneID.deviceId)
        let closed = expectation(description: "source closes keyChanged")
        closed.assertForOverFulfill = false
        final class ReasonBox: @unchecked Sendable { var reason: String? }
        let rbox = ReasonBox()
        source.onReady = { _ in XCTFail("must not stream after a key change") }
        source.onClosed = { r in rbox.reason = r; closed.fulfill() }
        source.start()

        wait(for: [closed], timeout: 15)
        XCTAssertEqual(rbox.reason, SessionConstants.keyChangedReason)
        XCTAssertEqual(sourceTap.sentCount(of: .pairProof), 0, "no proof/data flows after keyChanged")
        XCTAssertEqual(sourceTap.sentCount(of: .hello), 0)
        listener.stop()
    }

    // MARK: - Rate limiting

    func testRateLimitAfterFiveFailures() throws {
        let displayID = try bag.make()
        let displayTrust = InMemoryTrustStore()
        let limiter = PairingRateLimiter(threshold: 5, baseLockout: 60, cap: 900)
        let (listener, port) = startDisplay(identity: displayID, trust: displayTrust, pin: "111111",
                                            rateLimiter: limiter)

        // Five consecutive wrong-PIN attempts → each closes with "auth".
        for i in 0..<5 {
            let sID = try bag.make()
            let (source, _) = makeSource(port: port, identity: sID, pin: "999999", trust: InMemoryTrustStore())
            let closed = expectation(description: "attempt \(i) closes")
            closed.assertForOverFulfill = false
            final class RB: @unchecked Sendable { var r: String? }
            let rb = RB()
            source.onClosed = { r in rb.r = r; closed.fulfill() }
            source.start()
            wait(for: [closed], timeout: 15)
            XCTAssertEqual(rb.r, SessionConstants.authFailureReason, "attempt \(i) should be auth")
        }

        // The sixth attempt is refused immediately with "rateLimited" (even a correct PIN).
        let sID = try bag.make()
        let (source, sourceTap) = makeSource(port: port, identity: sID, pin: "111111", trust: InMemoryTrustStore())
        let closed = expectation(description: "sixth refused")
        closed.assertForOverFulfill = false
        final class RB: @unchecked Sendable { var r: String? }
        let rb = RB()
        source.onClosed = { r in rb.r = r; closed.fulfill() }
        source.start()
        wait(for: [closed], timeout: 15)
        XCTAssertEqual(rb.r, SessionConstants.rateLimitedReason)
        XCTAssertGreaterThan(sourceTap.receivedCount(of: .bye), 0)
        listener.stop()
    }
}
