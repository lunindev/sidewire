import XCTest
@testable import SidewireCore
import SidewireProtocol

/// Validates the TLS-PSK layer over the real Network.framework TLS stack on 127.0.0.1:
/// matching keys establish an encrypted session; a mismatched key must fail the handshake.
final class SecurityTests: XCTestCase {

    private func caps() -> Capabilities {
        Capabilities(videoCodecs: ["hevc"], maxWidth: 3840, maxHeight: 2160, maxFps: 60,
                     ltr: false, audio: false, hdr: false)
    }

    private func displayHello() -> Hello {
        Hello(role: .display, deviceId: "d", deviceName: "D", sessionId: "s", capabilities: caps())
    }
    private func sourceHello() -> Hello {
        Hello(role: .source, deviceId: "s", deviceName: "S", sessionId: "s", capabilities: caps())
    }

    final class Box: @unchecked Sendable { var session: Session? }

    func testTLSPSKHandshakeSucceedsWithMatchingKey() {
        let psk = PSKCredential(key: Data(repeating: 0x42, count: 32), identity: "sidewire")
        let listener = TCPListener(serviceName: "sec-test")
        var boundPort: UInt16 = 0
        let portReady = expectation(description: "bound")
        listener.onReady = { p in boundPort = p; portReady.fulfill() }

        let box = Box()
        let displayReady = expectation(description: "display ready")
        let gotVideo = expectation(description: "encrypted video round-trip")

        listener.onConnection = { [caps] transport in
            let s = Session(transport: transport, role: .display,
                            localHello: Hello(role: .display, deviceId: "d", deviceName: "D",
                                              sessionId: "s", capabilities: caps()))
            s.provideDisplayInfo = { DisplayInfo(width: 1920, height: 1200, scaleFactor: 2, refreshRate: 60, name: "t") }
            box.session = s
            s.onReady = { _ in displayReady.fulfill() }
            s.onVideoFrame = { nal, _, _ in
                XCTAssertEqual(nal, Data([1, 2, 3]))
                gotVideo.fulfill()
            }
            s.start()
        }
        listener.start(port: 0, advertise: false, psk: psk)
        wait(for: [portReady], timeout: 5)

        let clientTransport = TCPTransport(host: "127.0.0.1", port: boundPort, psk: psk)
        let source = Session(transport: clientTransport, role: .source, localHello: sourceHello())
        let sourceReady = expectation(description: "source ready")
        source.onReady = { _ in sourceReady.fulfill() }
        source.start()

        wait(for: [sourceReady, displayReady], timeout: 10) // TLS handshake takes a moment
        source.sendVideo(Data([1, 2, 3]), keyframe: true)
        wait(for: [gotVideo], timeout: 5)

        source.close(reason: "user")
        listener.stop()
    }

    func testTLSPSKMismatchedKeyFails() {
        let serverPSK = PSKCredential(key: Data(repeating: 0x01, count: 32), identity: "sidewire")
        let clientPSK = PSKCredential(key: Data(repeating: 0x02, count: 32), identity: "sidewire") // wrong key
        let listener = TCPListener(serviceName: "sec-test2")
        var boundPort: UInt16 = 0
        let portReady = expectation(description: "bound")
        listener.onReady = { p in boundPort = p; portReady.fulfill() }

        let box = Box()
        listener.onConnection = { [caps] transport in
            let s = Session(transport: transport, role: .display,
                            localHello: Hello(role: .display, deviceId: "d", deviceName: "D",
                                              sessionId: "s", capabilities: caps()))
            s.provideDisplayInfo = { DisplayInfo(width: 1920, height: 1200, scaleFactor: 2, refreshRate: 60, name: "t") }
            box.session = s
            s.start()
        }
        listener.start(port: 0, advertise: false, psk: serverPSK)
        wait(for: [portReady], timeout: 5)

        let clientTransport = TCPTransport(host: "127.0.0.1", port: boundPort, psk: clientPSK)
        let source = Session(transport: clientTransport, role: .source, localHello: sourceHello())
        let closed = expectation(description: "handshake fails / session closes")
        closed.assertForOverFulfill = false
        source.onReady = { _ in XCTFail("must not reach streaming with a wrong PSK") }
        source.onClosed = { _ in closed.fulfill() }
        source.start()

        // TLS failure surfaces as .failed quickly; the connect timeout (10s) is the backstop.
        wait(for: [closed], timeout: 13)
        listener.stop()
    }
}
