import XCTest
@testable import SidewireProtocol

final class FrameTests: XCTestCase {

    func testHeaderRoundTrip() throws {
        let payload = Data([1, 2, 3, 4, 5])
        let encoded = FrameEncoder.encode(type: .video, flags: VideoFlags.keyframe.rawValue,
                                           seq: 42, payload: payload)
        XCTAssertEqual(encoded.count, ProtocolConstants.frameHeaderBytes + payload.count)

        let parser = FrameParser()
        let frames = try parser.append(encoded)
        XCTAssertEqual(frames.count, 1)
        let f = frames[0]
        XCTAssertEqual(f.type, .video)
        XCTAssertEqual(f.flags, VideoFlags.keyframe.rawValue)
        XCTAssertEqual(f.seq, 42)
        XCTAssertEqual(f.payload, payload)
        XCTAssertEqual(parser.pendingByteCount, 0)
    }

    func testEmptyPayload() throws {
        let encoded = FrameEncoder.encode(type: .requestIDR, flags: 0, seq: 7, payload: Data())
        let frames = try FrameParser().append(encoded)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].type, .requestIDR)
        XCTAssertEqual(frames[0].payload.count, 0)
    }

    func testPartialReadsReassemble() throws {
        let payload = Data(repeating: 0xAB, count: 1000)
        let encoded = FrameEncoder.encode(type: .video, flags: 0, seq: 1, payload: payload)
        let parser = FrameParser()

        // Split into three arbitrary chunks, including one that cuts the header.
        let c1 = encoded.prefix(5)
        let c2 = encoded.dropFirst(5).prefix(500)
        let c3 = encoded.dropFirst(505)

        XCTAssertEqual(try parser.append(Data(c1)).count, 0)
        XCTAssertEqual(try parser.append(Data(c2)).count, 0)
        let frames = try parser.append(Data(c3))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].payload, payload)
    }

    func testMultipleFramesInOneChunk() throws {
        var buf = Data()
        buf.append(FrameEncoder.encode(type: .ping, flags: 0, seq: 0, payload: Data([9])))
        buf.append(FrameEncoder.encode(type: .pong, flags: 0, seq: 1, payload: Data([8])))
        buf.append(FrameEncoder.encode(type: .input, flags: 0, seq: 2, payload: Data([7])))

        let frames = try FrameParser().append(buf)
        XCTAssertEqual(frames.map(\.type), [.ping, .pong, .input])
        XCTAssertEqual(frames.map(\.seq), [0, 1, 2])
    }

    /// The forward-compatibility guarantee: an unknown/reserved type is parsed and
    /// skipped by length, and the following known frame is intact.
    func testUnknownTypeIsSkippedNotFatal() throws {
        let unknownType: UInt8 = 0x7A // reserved range
        var buf = Data()
        buf.append(FrameEncoder.encode(rawType: unknownType, flags: 0, seq: 100,
                                       payload: Data(repeating: 0xEE, count: 64)))
        buf.append(FrameEncoder.encode(type: .config, flags: 0, seq: 101, payload: Data([1, 2])))

        let frames = try FrameParser().append(buf)
        XCTAssertEqual(frames.count, 2)
        XCTAssertNil(frames[0].type, "unknown type should decode as nil MessageType")
        XCTAssertEqual(frames[0].rawType, unknownType)
        XCTAssertEqual(frames[1].type, .config, "known frame after an unknown one must be intact")
        XCTAssertEqual(frames[1].payload, Data([1, 2]))
    }

    func testFrameTooLargeThrows() {
        // Hand-craft a header claiming a huge payload.
        var buf = Data()
        buf.append(MessageType.video.rawValue)
        buf.append(0); buf.append(0); buf.append(0)
        let huge = UInt32(ProtocolConstants.maxFrameBytes) + 1
        buf.append(UInt8((huge >> 24) & 0xFF)); buf.append(UInt8((huge >> 16) & 0xFF))
        buf.append(UInt8((huge >> 8) & 0xFF)); buf.append(UInt8(huge & 0xFF))
        buf.append(contentsOf: [0, 0, 0, 0]) // seq

        XCTAssertThrowsError(try FrameParser().append(buf)) { error in
            XCTAssertEqual(error as? FrameParser.ParseError, .frameTooLarge(huge))
        }
    }
}
