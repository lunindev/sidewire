import XCTest
@testable import SidewireCore
import SidewireProtocol

/// End-to-end test over the REAL Network.framework TCP stack on 127.0.0.1 — a Source
/// and a Display session talking through an actual NWListener/NWConnection, no second
/// machine and no permissions. This exercises the exact path that produced the
/// "reason=user" and "Connection reset" field bugs, so those classes are caught here.
final class LoopbackIntegrationTests: XCTestCase {

    private var bag: IdentityBag!
    override func setUp() { super.setUp(); bag = IdentityBag() }
    override func tearDown() { bag.destroyAll(); super.tearDown() }

    private func caps() -> Capabilities {
        Capabilities(videoCodecs: ["hevc"], maxWidth: 3840, maxHeight: 2160, maxFps: 60,
                     ltr: false, audio: false, hdr: false)
    }

    func testRealTCPHandshakeAndRoundTrip() throws {
        // Real TLS 1.3 with throwaway device identities. No pairingConfig ⇒ the Session treats
        // the link as trusted and goes straight to the handshake (pairing itself is covered by
        // SecurityTests); this exercises the cert-TLS transport + framing + relay end to end.
        let displayID = try bag.make(), sourceID = try bag.make()
        let listener = TCPListener(serviceName: "sidewire-test")

        let portReady = expectation(description: "listener bound")
        var boundPort: UInt16 = 0
        listener.onReady = { p in boundPort = p; portReady.fulfill() }

        // Hold a strong ref to the display session created on accept.
        final class Box: @unchecked Sendable { var session: Session? }
        let box = Box()

        let displayReady = expectation(description: "display ready")
        let sourceReady = expectation(description: "source ready")
        let gotVideo = expectation(description: "display received video")
        let gotInput = expectation(description: "source received input")

        listener.onConnection = { [caps] transport in
            let hello = Hello(role: .display, deviceId: "disp", deviceName: "DisplayTest",
                              sessionId: "s", capabilities: caps())
            let s = Session(transport: transport, role: .display, localHello: hello)
            box.session = s
            s.provideDisplayInfo = {
                DisplayInfo(width: 1920, height: 1200, scaleFactor: 2, refreshRate: 60, name: "test")
            }
            s.onReady = { _ in displayReady.fulfill() }
            s.onVideoFrame = { nal, isKey, _, pts in
                XCTAssertEqual(nal, Data([0x00, 0x00, 0x00, 0x01, 0x42]))
                XCTAssertTrue(isKey)
                XCTAssertEqual(pts, 42_000_000_000, "PTS must round-trip end to end over real TLS")
                gotVideo.fulfill()
            }
            s.start()
        }

        // Loopback: ephemeral port, no Bonjour advertisement.
        listener.start(port: 0, advertise: false, identity: displayID)
        wait(for: [portReady], timeout: 5)
        XCTAssertGreaterThan(boundPort, 0)

        let clientTransport = TCPTransport(host: "127.0.0.1", port: boundPort, identity: sourceID)
        let sourceHello = Hello(role: .source, deviceId: "src", deviceName: "SourceTest",
                                sessionId: "s", capabilities: caps())
        let sourceSession = Session(transport: clientTransport, role: .source, localHello: sourceHello)
        sourceSession.onReady = { _ in sourceReady.fulfill() }
        sourceSession.onInputEvent = { rec in
            XCTAssertEqual(rec.type, .mouseDown)
            gotInput.fulfill()
        }
        sourceSession.start()

        wait(for: [sourceReady, displayReady], timeout: 10) // TLS 1.3 handshake adds a moment

        // Round-trip a video frame (source→display) and an input event (display→source).
        sourceSession.sendVideo(Data([0x00, 0x00, 0x00, 0x01, 0x42]), keyframe: true, ltrToken: 0,
                                ptsNanos: 42_000_000_000)
        box.session?.sendInput(InputEventRecord(type: .mouseDown, x: 0.5, y: 0.5))

        wait(for: [gotVideo, gotInput], timeout: 5)

        sourceSession.close(reason: "user")
        listener.stop()
    }
}
