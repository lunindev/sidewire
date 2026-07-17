import XCTest
@testable import SidewireCore
import SidewireProtocol

/// An in-memory `Transport` that delivers frames directly to a linked peer, so the
/// `Session` handshake/relay logic can be tested without sockets or a second machine.
private final class FakeTransport: Transport, @unchecked Sendable {
    var onFrame: ((Frame) -> Void)?
    var onState: ((TransportState) -> Void)?
    var onInterface: ((String) -> Void)?
    var onSecurity: ((TLSPeerInfo) -> Void)? // never fired ⇒ Session skips the PIN proof
    weak var peer: FakeTransport?

    func start() { onState?(.ready) }
    func cancel() { onState?(.cancelled) }

    func send(rawType: UInt8, flags: UInt8, seq: UInt32, payload: Data) {
        let frame = Frame(rawType: rawType, flags: flags, seq: seq, payload: payload)
        peer?.onFrame?(frame)
    }
}

final class SessionHandshakeTests: XCTestCase {

    private func caps(_ codecs: [String]) -> Capabilities {
        Capabilities(videoCodecs: codecs, maxWidth: 3456, maxHeight: 2234, maxFps: 60,
                     ltr: true, audio: false, hdr: false)
    }

    func testFullHandshakeAndRelay() {
        let sourceT = FakeTransport(), displayT = FakeTransport()
        sourceT.peer = displayT
        displayT.peer = sourceT

        let sourceHello = Hello(role: .source, deviceId: "src", deviceName: "M4 Max",
                                sessionId: "s1", capabilities: caps(["hevc", "h264"]))
        let displayHello = Hello(role: .display, deviceId: "dsp", deviceName: "i9",
                                 sessionId: "s1", capabilities: caps(["h264"]))

        let source = Session(transport: sourceT, role: .source, localHello: sourceHello)
        let display = Session(transport: displayT, role: .display, localHello: displayHello)

        let nativeInfo = DisplayInfo(width: 1920, height: 1200, scaleFactor: 2.0,
                                     refreshRate: 60, name: "i9 Panel")
        display.provideDisplayInfo = { nativeInfo }

        let sourceReady = expectation(description: "source ready")
        let displayReady = expectation(description: "display ready")
        let gotVideo = expectation(description: "display got video")
        let gotInput = expectation(description: "source got input")

        var sourceConfig: Config?
        var displayConfig: Config?

        source.onReady = { cfg in sourceConfig = cfg; sourceReady.fulfill() }
        display.onReady = { cfg in displayConfig = cfg; displayReady.fulfill() }

        display.onVideoFrame = { nal, isKey, token, pts in
            XCTAssertEqual(nal, Data([0xAA, 0xBB]))
            XCTAssertTrue(isKey)
            XCTAssertEqual(token, 3)
            XCTAssertEqual(pts, 987_654_321, "video PTS must round-trip through the subheader")
            gotVideo.fulfill()
        }
        source.onInputEvent = { rec in
            XCTAssertEqual(rec.type, .mouseDown)
            gotInput.fulfill()
        }

        // Start both; order doesn't matter (both send HELLO on ready).
        display.start()
        source.start()

        wait(for: [sourceReady, displayReady], timeout: 2.0)

        // Negotiation: only common codec is h264; dims match the display's native panel.
        XCTAssertEqual(sourceConfig?.codec, "h264")
        XCTAssertEqual(sourceConfig, displayConfig)
        XCTAssertEqual(sourceConfig?.width, 1920)
        XCTAssertEqual(sourceConfig?.height, 1200)

        // Relay a frame each way (with a PTS that must survive the round-trip).
        source.sendVideo(Data([0xAA, 0xBB]), keyframe: true, ltrToken: 3, ptsNanos: 987_654_321)
        display.sendInput(InputEventRecord(type: .mouseDown, x: 0.5, y: 0.5))

        wait(for: [gotVideo, gotInput], timeout: 2.0)
    }

    func testNoCommonCodecClosesProtocol() {
        let sourceT = FakeTransport(), displayT = FakeTransport()
        sourceT.peer = displayT
        displayT.peer = sourceT

        // Disjoint codec sets: source speaks only HEVC, display only H.264.
        let sourceHello = Hello(role: .source, deviceId: "src", deviceName: "M4 Max",
                                sessionId: "s1", capabilities: caps(["hevc"]))
        let displayHello = Hello(role: .display, deviceId: "dsp", deviceName: "i9",
                                 sessionId: "s1", capabilities: caps(["h264"]))

        let source = Session(transport: sourceT, role: .source, localHello: sourceHello)
        let display = Session(transport: displayT, role: .display, localHello: displayHello)
        display.provideDisplayInfo = {
            DisplayInfo(width: 1920, height: 1200, scaleFactor: 2.0, refreshRate: 60, name: "i9 Panel")
        }

        source.onReady = { _ in XCTFail("must not reach ready with no common codec") }
        display.onReady = { _ in XCTFail("must not reach ready with no common codec") }

        let sourceClosed = expectation(description: "source closed protocol")
        let displayClosed = expectation(description: "display closed protocol")
        sourceClosed.assertForOverFulfill = false
        displayClosed.assertForOverFulfill = false
        source.onClosed = { reason in
            XCTAssertEqual(reason, HelloRejection.protocolMismatch.rawValue)
            sourceClosed.fulfill()
        }
        display.onClosed = { reason in
            XCTAssertEqual(reason, HelloRejection.protocolMismatch.rawValue)
            displayClosed.fulfill()
        }

        display.start()
        source.start()
        wait(for: [sourceClosed, displayClosed], timeout: 2.0)
    }

    func testRoleConflictIsRejected() {
        let aT = FakeTransport(), bT = FakeTransport()
        aT.peer = bT; bT.peer = aT

        // Two Sources — invalid pairing.
        let helloA = Hello(role: .source, deviceId: "a", deviceName: "A",
                           sessionId: "s", capabilities: caps(["hevc"]))
        let helloB = Hello(role: .source, deviceId: "b", deviceName: "B",
                           sessionId: "s", capabilities: caps(["hevc"]))
        let a = Session(transport: aT, role: .source, localHello: helloA)
        let b = Session(transport: bT, role: .source, localHello: helloB)

        let closed = expectation(description: "closed on role conflict")
        closed.assertForOverFulfill = false
        a.onClosed = { reason in
            XCTAssertEqual(reason, HelloRejection.roleConflict.rawValue)
            closed.fulfill()
        }
        b.onClosed = { _ in }

        b.start()
        a.start()
        wait(for: [closed], timeout: 2.0)
    }

    /// Fail loud: a malformed handshake JSON must close with BYE("protocol"), not silently drop
    /// and hang to the 10s timeout (Phase 7b item 3).
    func testMalformedHelloClosesProtocol() {
        let sT = FakeTransport(), dT = FakeTransport()
        sT.peer = dT; dT.peer = sT
        let hello = Hello(role: .source, deviceId: "src", deviceName: "S",
                          sessionId: "s", capabilities: caps(["hevc"]))
        let source = Session(transport: sT, role: .source, localHello: hello)

        let closed = expectation(description: "closed protocol on malformed HELLO")
        closed.assertForOverFulfill = false
        source.onClosed = { reason in
            XCTAssertEqual(reason, HelloRejection.protocolMismatch.rawValue)
            closed.fulfill()
        }
        source.start()
        // The "peer" sends unparseable HELLO bytes.
        dT.send(type: .hello, seq: 0, payload: Data("not json at all".utf8))
        wait(for: [closed], timeout: 2.0)
    }

    /// Peers that advertise a different `inputMapping` must be refused with BYE("protocol").
    func testInputMappingMismatchClosesProtocol() {
        let sT = FakeTransport(), dT = FakeTransport()
        sT.peer = dT; dT.peer = sT
        let displayHello = Hello(role: .display, deviceId: "dsp", deviceName: "D",
                                 sessionId: "s", capabilities: caps(["hevc"])) // inputMapping "hid1"
        let display = Session(transport: sT, role: .display, localHello: displayHello)

        let closed = expectation(description: "closed protocol on mapping mismatch")
        closed.assertForOverFulfill = false
        display.onClosed = { reason in
            XCTAssertEqual(reason, HelloRejection.protocolMismatch.rawValue)
            closed.fulfill()
        }
        display.start()

        var badCaps = caps(["hevc"])
        badCaps.inputMapping = "hid2" // a mapping we don't speak
        let sourceHello = Hello(role: .source, deviceId: "src", deviceName: "S",
                                sessionId: "s", capabilities: badCaps)
        dT.send(type: .hello, seq: 0, payload: JSONWire.encode(sourceHello))
        wait(for: [closed], timeout: 2.0)
    }

    /// E6: the Display must send DISPLAY_INFO only AFTER receiving+validating the peer's HELLO
    /// (right after its HELLO_ACK), never before — so a rejected peer never learns the panel.
    func testDisplaySendsDisplayInfoOnlyAfterPeerHello() {
        let displayT = FakeTransport(), driverT = FakeTransport()
        displayT.peer = driverT; driverT.peer = displayT

        let lock = NSLock()
        var received: [UInt8] = []
        let helloSeen = expectation(description: "display sent HELLO")
        helloSeen.assertForOverFulfill = false
        let infoSeen = expectation(description: "display sent DISPLAY_INFO")
        infoSeen.assertForOverFulfill = false
        driverT.onFrame = { frame in
            lock.lock(); received.append(frame.rawType); lock.unlock()
            if frame.rawType == MessageType.hello.rawValue { helloSeen.fulfill() }
            if frame.rawType == MessageType.displayInfo.rawValue { infoSeen.fulfill() }
        }

        let displayHello = Hello(role: .display, deviceId: "dsp", deviceName: "D",
                                 sessionId: "s", capabilities: caps(["hevc"]))
        let display = Session(transport: displayT, role: .display, localHello: displayHello)
        display.provideDisplayInfo = {
            DisplayInfo(width: 1920, height: 1200, scaleFactor: 2.0, refreshRate: 60, name: "panel")
        }
        display.start()

        wait(for: [helloSeen], timeout: 2.0)
        lock.lock(); let sentInfoEarly = received.contains(MessageType.displayInfo.rawValue); lock.unlock()
        XCTAssertFalse(sentInfoEarly, "DISPLAY_INFO must not precede the peer HELLO")

        // Now the Source's HELLO arrives; the Display should reply HELLO_ACK then DISPLAY_INFO.
        let sourceHello = Hello(role: .source, deviceId: "src", deviceName: "S",
                                sessionId: "s", capabilities: caps(["hevc"]))
        driverT.send(type: .hello, seq: 0, payload: JSONWire.encode(sourceHello))

        wait(for: [infoSeen], timeout: 2.0)
        lock.lock(); let order = received; lock.unlock()
        let ackIdx = order.firstIndex(of: MessageType.helloAck.rawValue)
        let infoIdx = order.firstIndex(of: MessageType.displayInfo.rawValue)
        XCTAssertNotNil(ackIdx, "the Display must send a HELLO_ACK")
        XCTAssertNotNil(infoIdx)
        if let a = ackIdx, let i = infoIdx {
            XCTAssertLessThan(a, i, "DISPLAY_INFO comes right after the HELLO_ACK")
        }
        display.close(reason: "user")
    }
}
