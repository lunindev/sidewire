import XCTest
@testable import SidewireProtocol

final class MessageTests: XCTestCase {

    private func sampleCaps() -> Capabilities {
        Capabilities(videoCodecs: ["hevc", "h264"], maxWidth: 3456, maxHeight: 2234,
                     maxFps: 60, ltr: true, audio: false, hdr: false)
    }

    func testHelloJSONRoundTrip() throws {
        let hello = Hello(role: .source, deviceId: "dev-1", deviceName: "M4 Max",
                          sessionId: "sess-1", capabilities: sampleCaps())
        let data = JSONWire.encode(hello)
        let back = JSONWire.decode(Hello.self, from: data)
        XCTAssertEqual(back, hello)
    }

    func testHelloValidation() {
        let displayHello = Hello(role: .display, deviceId: "d", deviceName: "i9",
                                 sessionId: "s", capabilities: sampleCaps())
        // A source validating a display's HELLO: OK.
        XCTAssertNil(displayHello.validate(againstLocalRole: .source))
        // A display validating another display's HELLO: role conflict.
        XCTAssertEqual(displayHello.validate(againstLocalRole: .display), .roleConflict)

        var badMagic = displayHello
        badMagic.magic = "NOPE"
        XCTAssertEqual(badMagic.validate(againstLocalRole: .source), .badMagic)

        var badVersion = displayHello
        badVersion.version = ProtocolVersion(major: 1, minor: 0) // v1 peer rejected by v2
        XCTAssertEqual(badVersion.validate(againstLocalRole: .source), .protocolMismatch)
    }

    func testConfigAndDisplayInfoRoundTrip() {
        let cfg = Config(codec: "hevc", width: 2560, height: 1600, fps: 60, ltr: true,
                         bitrateStartBps: 30_000_000, bitrateMinBps: 5_000_000,
                         bitrateMaxBps: 50_000_000)
        XCTAssertEqual(JSONWire.decode(Config.self, from: JSONWire.encode(cfg)), cfg)

        let info = DisplayInfo(width: 2560, height: 1600, scaleFactor: 2.0,
                               refreshRate: 60, name: "Built-in Retina Display")
        XCTAssertEqual(JSONWire.decode(DisplayInfo.self, from: JSONWire.encode(info)), info)
    }

    func testInputEventRecordRoundTrip() {
        let rec = InputEventRecord(type: .scrollWheel, buttonNumber: 2, clickCount: 1,
                                   modifierFlags: 0x0102_0304_0506_0708,
                                   x: 0.25, y: 0.75, deltaX: -3.5, deltaY: 12.0, keyCode: 53)
        let data = rec.encoded
        XCTAssertEqual(data.count, ProtocolConstants.inputRecordBytes)
        XCTAssertEqual(InputEventRecord.decode(from: data), rec)
    }

    func testInputEventBatchDecode() {
        let a = InputEventRecord(type: .mouseMove, x: 0.1, y: 0.1)
        let b = InputEventRecord(type: .mouseMove, x: 0.2, y: 0.2)
        var batch = a.encoded
        batch.append(b.encoded)
        let decoded = InputEventRecord.decodeBatch(from: batch)
        XCTAssertEqual(decoded, [a, b])
    }

    func testVideoPayloadRoundTrip() {
        let nal = Data([0x00, 0x00, 0x00, 0x01, 0x40, 0x01, 0xFF])
        let payload = VideoPayload.encode(ltrToken: 7, nalData: nal)
        let decoded = VideoPayload.decode(payload)
        XCTAssertEqual(decoded?.ltrToken, 7)
        XCTAssertEqual(decoded?.nalData, nal)
    }

    func testHeartbeatPayloadRoundTrip() {
        let ts: UInt64 = 123_456_789_012
        XCTAssertEqual(HeartbeatPayload.decode(HeartbeatPayload.encode(ts)), ts)
    }

    func testLTRAckRoundTrip() {
        let tokens: [UInt16] = [1, 5, 900, 65535]
        XCTAssertEqual(LTRAckPayload.decode(LTRAckPayload.encode(tokens)), tokens)
    }
}
