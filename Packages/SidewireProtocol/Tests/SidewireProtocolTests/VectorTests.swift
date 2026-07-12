import XCTest
@testable import SidewireProtocol

// MARK: - Vector document shapes (mirrored in protocol-vectors/*.json)

private struct FrameVector: Codable, Equatable {
    let name: String
    let description: String
    let type: UInt8
    let flags: UInt8
    let seq: UInt32
    let payloadHex: String
    let frameHex: String
}
private struct FrameDoc: Codable, Equatable {
    let note: String
    let vectors: [FrameVector]
}

private struct MessageVector<M: Codable & Equatable>: Codable, Equatable {
    let name: String
    let description: String
    /// The message shown natively (parse by field name — JSON is order-independent). This IS the
    /// canonical example; there is deliberately no byte-exact hex because JSON key order is not
    /// significant and Foundation's encoder does not even fix it across runs.
    let message: M
}
private struct MessageDoc: Codable, Equatable {
    let note: String
    let hello: [MessageVector<Hello>]
    let config: [MessageVector<Config>]
    let displayInfo: [MessageVector<DisplayInfo>]
    let bye: [MessageVector<ReasonMessage>]
}

private struct InputVector: Codable, Equatable {
    let name: String
    let description: String
    let eventType: UInt8
    let buttonNumber: UInt8
    let clickCount: UInt8
    let modifiers: UInt8
    let x: Float
    let y: Float
    let deltaX: Float
    let deltaY: Float
    let keyCode: UInt16
    let hex: String
}
private struct InputDoc: Codable, Equatable {
    let note: String
    let vectors: [InputVector]
}

private struct VideoVector: Codable, Equatable {
    let name: String
    let description: String
    let ltrToken: UInt16
    let ptsNanos: UInt64
    let nalHex: String
    let payloadHex: String
}
private struct VideoDoc: Codable, Equatable {
    let note: String
    let vectors: [VideoVector]
}

/// Generates (with `SIDEWIRE_WRITE_VECTORS=1`) and otherwise verifies the wire golden vectors.
final class VectorTests: XCTestCase {

    // MARK: Frame header vectors

    func testFrameVectors() {
        func fv(_ name: String, _ desc: String, type: UInt8, flags: UInt8 = 0, seq: UInt32, payload: Data) -> FrameVector {
            let frame = FrameEncoder.encode(rawType: type, flags: flags, seq: seq, payload: payload)
            return FrameVector(name: name, description: desc, type: type, flags: flags, seq: seq,
                               payloadHex: payload.vectorHex, frameHex: frame.vectorHex)
        }
        let videoPayload = VideoPayload.encode(ltrToken: 0, ptsNanos: 0x0102_0304_0506_0708,
                                               nalData: Data([0x00, 0x00, 0x00, 0x01, 0x40, 0x01, 0xFF]))
        let inputPayload = InputEventRecord(type: .mouseDown, buttonNumber: 0, clickCount: 1,
                                            modifiers: 0, x: 0.5, y: 0.5).encoded
        let doc = FrameDoc(
            note: "12-byte header: type(1) flags(1) reserved(2=0) length(4,BE) seq(4,BE), then payload. Unknown/reserved types are skipped by length. Reject length > 16 MiB.",
            vectors: [
                fv("hello", "HELLO frame, JSON payload (see message-vectors.json for the JSON).",
                   type: MessageType.hello.rawValue, seq: 0,
                   payload: Data("{\"x\":1}".utf8)),
                fv("hello_ack", "HELLO_ACK frame — same JSON shape as HELLO, only the type byte differs.",
                   type: MessageType.helloAck.rawValue, seq: 1,
                   payload: Data("{\"x\":1}".utf8)),
                fv("pair_proof", "PAIR_PROOF frame: 32-byte HMAC payload (example bytes; real proofs in pairing-vectors.json).",
                   type: MessageType.pairProof.rawValue, seq: 0,
                   payload: Data((0..<32).map { UInt8($0) })),
                fv("pair_ack", "PAIR_ACK frame: empty payload.",
                   type: MessageType.pairAck.rawValue, seq: 1, payload: Data()),
                fv("video_keyframe", "VIDEO frame, keyframe flag (0x01) set, seq 42, 12-byte subheader + Annex-B.",
                   type: MessageType.video.rawValue, flags: VideoFlags.keyframe.rawValue, seq: 42,
                   payload: videoPayload),
                fv("input", "INPUT frame: one 32-byte record (see input-vectors.json).",
                   type: MessageType.input.rawValue, seq: 7, payload: inputPayload),
                fv("ping", "PING frame: 8-byte big-endian monotonic-nanos payload.",
                   type: MessageType.ping.rawValue, seq: 100,
                   payload: HeartbeatPayload.encode(0x1122_3344_5566_7788)),
                fv("request_idr", "REQUEST_IDR frame: empty payload (edge: length 0).",
                   type: MessageType.requestIDR.rawValue, seq: 5, payload: Data()),
                fv("bye", "BYE frame: JSON {reason}. Here reason=\"user\".",
                   type: MessageType.bye.rawValue, seq: 9,
                   payload: JSONWire.encode(ReasonMessage(reason: "user"))),
                fv("seq_wrap", "seq at its maximum (0xFFFFFFFF); the next seq wraps to 0.",
                   type: MessageType.ping.rawValue, seq: 0xFFFF_FFFF,
                   payload: HeartbeatPayload.encode(1)),
                fv("unknown_reserved_type", "Reserved type 0x7A: a conformant reader skips it by length and continues.",
                   type: 0x7A, seq: 100, payload: Data([0xDE, 0xAD, 0xBE, 0xEF])),
            ])
        Vectors.sync("frame-vectors.json", doc)
    }

    // MARK: JSON control-message vectors

    func testMessageVectors() {
        let caps = Capabilities(videoCodecs: ["hevc", "h264"], maxWidth: 3456, maxHeight: 2234,
                                maxFps: 60, ltr: true, audio: false, hdr: false, inputMapping: "hid1")
        let hello = Hello(role: .source, deviceId: "a1b2c3d4e5f6a7b8", deviceName: "Sidewire Mac",
                          sessionId: "00000000-0000-0000-0000-000000000000", capabilities: caps,
                          version: ProtocolVersion(major: 2, minor: 0))
        let config = Config(codec: "hevc", width: 2560, height: 1600, fps: 60, ltr: true,
                            bitrateStartBps: 30_000_000, bitrateMinBps: 5_000_000,
                            bitrateMaxBps: 50_000_000, hiDPI: true)
        let info = DisplayInfo(width: 2560, height: 1600, scaleFactor: 2.0, refreshRate: 60,
                               name: "Built-in Retina Display")

        func mv<M: Codable & Equatable>(_ name: String, _ desc: String, _ m: M) -> MessageVector<M> {
            MessageVector(name: name, description: desc, message: m)
        }
        let doc = MessageDoc(
            note: "Cold-path JSON messages. Match SEMANTICALLY: decode and compare fields — JSON key order is NOT significant (and is not fixed on the wire). The `message` object here is the canonical field set. HELLO_ACK uses the identical Hello shape (only the frame type byte differs: 0x02 vs 0x01). Decoders MUST ignore unknown fields; fields beyond the v2 required set are optional-with-defaults (e.g. capabilities.inputMapping defaults to \"hid1\", config.hiDPI to true).",
            hello: [mv("hello_source", "Canonical source HELLO (protocol v2.0).", hello)],
            config: [mv("config_hevc_1600p", "Canonical CONFIG for a 2560x1600 HEVC stream.", config)],
            displayInfo: [mv("display_info_retina", "Canonical DISPLAY_INFO for a 2x Retina panel.", info)],
            bye: [mv("bye_auth", "BYE with the fatal auth (wrong-PIN) reason.", ReasonMessage(reason: "auth")),
                  mv("bye_user", "BYE with the graceful user-disconnect reason.", ReasonMessage(reason: "user"))])
        Vectors.sync("message-vectors.json", doc)
    }

    // MARK: Input record vectors

    func testInputVectors() {
        func iv(_ name: String, _ desc: String, _ r: InputEventRecord) -> InputVector {
            InputVector(name: name, description: desc, eventType: r.type.rawValue,
                        buttonNumber: r.buttonNumber, clickCount: r.clickCount, modifiers: r.modifiers,
                        x: r.x, y: r.y, deltaX: r.deltaX, deltaY: r.deltaY, keyCode: r.keyCode,
                        hex: r.encoded.vectorHex)
        }
        let doc = InputDoc(
            note: "Fixed 32-byte input records. Integers big-endian, floats IEEE-754 big-endian. keyCode = USB HID keyboard usage (page 0x07); modifiers = HID boot-protocol modifier byte (bit0 LCtrl … bit7 RGui). Scroll deltas are in pixels. Bytes 4..11 and 30..31 are reserved (zero).",
            vectors: [
                iv("mouse_move_center", "Pointer move to the center of the video rect.",
                   InputEventRecord(type: .mouseMove, x: 0.5, y: 0.5)),
                iv("mouse_down_double", "Left double-click at (0.25, 0.75).",
                   InputEventRecord(type: .mouseDown, buttonNumber: 0, clickCount: 2, x: 0.25, y: 0.75)),
                iv("right_mouse_down", "Right button down at the bottom-left corner.",
                   InputEventRecord(type: .rightMouseDown, buttonNumber: 1, clickCount: 1, x: 0.0, y: 1.0)),
                iv("scroll_wheel", "Scroll with pixel deltas (dx=-3.5, dy=12.0).",
                   InputEventRecord(type: .scrollWheel, x: 0.5, y: 0.5, deltaX: -3.5, deltaY: 12.0)),
                iv("key_down_shift_a", "keyDown 'a' (HID usage 0x04) with Left Shift held.",
                   InputEventRecord(type: .keyDown, modifiers: HIDModifier.leftShift.rawValue, keyCode: 0x04)),
                iv("key_up_return", "keyUp Return (HID usage 0x28), no modifiers.",
                   InputEventRecord(type: .keyUp, keyCode: 0x28)),
                iv("flags_changed_left_shift", "flagsChanged for Left Shift (HID usage 0xE1); modifier bit set.",
                   InputEventRecord(type: .flagsChanged, modifiers: HIDModifier.leftShift.rawValue, keyCode: 0xE1)),
            ])
        Vectors.sync("input-vectors.json", doc)
    }

    // MARK: Video subheader vectors

    func testVideoVectors() {
        func vv(_ name: String, _ desc: String, ltr: UInt16, pts: UInt64, nal: Data) -> VideoVector {
            VideoVector(name: name, description: desc, ltrToken: ltr, ptsNanos: pts,
                        nalHex: nal.vectorHex,
                        payloadHex: VideoPayload.encode(ltrToken: ltr, ptsNanos: pts, nalData: nal).vectorHex)
        }
        let doc = VideoDoc(
            note: "VIDEO payload = 12-byte subheader + Annex-B NAL. Subheader (BE): ltrToken:u16 | flags:u16(=0) | pts:u64(nanoseconds). The keyframe bit lives in the FRAME header flags (0x01), not here. ltrToken is reserved (senders send 0).",
            vectors: [
                vv("keyframe_with_pts", "Keyframe payload, pts=0x0102030405060708 ns, ltrToken 0.",
                   ltr: 0, pts: 0x0102_0304_0506_0708,
                   nal: Data([0x00, 0x00, 0x00, 0x01, 0x40, 0x01, 0xFF])),
                vv("frame_zero_pts", "Frame with pts unspecified (0), e.g. a keep-alive resend.",
                   ltr: 0, pts: 0, nal: Data([0x00, 0x00, 0x00, 0x01, 0x42])),
            ])
        Vectors.sync("video-vectors.json", doc)
    }
}
