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

        display.onVideoFrame = { nal, isKey, token in
            XCTAssertEqual(nal, Data([0xAA, 0xBB]))
            XCTAssertTrue(isKey)
            XCTAssertEqual(token, 3)
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

        // Relay a frame each way.
        source.sendVideo(Data([0xAA, 0xBB]), keyframe: true, ltrToken: 3)
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
}
