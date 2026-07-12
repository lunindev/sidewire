import XCTest
import Crypto
@testable import SidewireCore
import SidewireProtocol

private struct CPaceVector: Codable, Equatable {
    let name: String
    let description: String
    let pin: String
    let clientSPKIHex: String
    let serverSPKIHex: String
    let channelBindingHex: String   // CI = SHA256(clientSPKI ‖ serverSPKI)
    let sidHex: String              // sid = SHA256(channelBinding)
    let scalarAHex: String          // injected Source (initiator) scalar ya
    let scalarBHex: String          // injected Display (responder) scalar yb
    let generatorHex: String        // g = calculate_generator(PIN, CI, sid)
    let shareAHex: String           // Ya = X25519(ya, g)
    let shareBHex: String           // Yb = X25519(yb, g)
    let kHex: String                // K = X25519(ya, Yb) = X25519(yb, Ya)
    let iskHex: String              // ISK = H(lv_cat(DSI_ISK,sid,K) ‖ transcript_ir)
    let macKeyHex: String           // mac_key = H("CPaceMac" ‖ sid ‖ ISK)
    let confirmAHex: String         // Ta = HMAC-SHA512(mac_key, lv_cat(Ya, ""))
    let confirmBHex: String         // Tb = HMAC-SHA512(mac_key, lv_cat(Yb, ""))
}
private struct CPaceDoc: Codable, Equatable {
    let note: String
    let ciphersuite: String
    let vectors: [CPaceVector]
}

/// Deterministic golden vectors for the CPace pairing exchange (docs/05). A foreign client
/// (Rust) reproduces every hex field from the fixed (PIN, clientSPKI, serverSPKI, scalars).
/// The scalars are the RNG-injection point that makes these reproducible; in a live session
/// they are fresh random bytes (`CPace.sampleScalar`).
final class VectorTests: XCTestCase {

    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    func testCPaceVectors() {
        // Fixed SPKI fingerprints (32 bytes each), matching the Phase-7a pattern for continuity.
        let clientSPKI = Data((0x00...0x1F).map { UInt8($0) })  // 00 01 … 1f
        let serverSPKI = Data((0x20...0x3F).map { UInt8($0) })  // 20 21 … 3f
        // Injected scalars = SHA-256 of a label (documented, reproducible). X25519 clamps them.
        let scalarA = [UInt8](Data(SHA256.hash(data: Data("sidewire-cpace-vector-scalar-a".utf8))))
        let scalarB = [UInt8](Data(SHA256.hash(data: Data("sidewire-cpace-vector-scalar-b".utf8))))

        func vector(_ name: String, _ desc: String, pin: String) -> CPaceVector {
            let cb = CPace.channelBinding(clientSPKI: clientSPKI, serverSPKI: serverSPKI)
            let sid = CPace.sid(channelBinding: cb)
            let g = CPace.calculateGenerator(pin: pin, ci: cb, sid: sid)
            let Ya = CPace.scalarMult(scalar: scalarA, u: g)!
            let Yb = CPace.scalarMult(scalar: scalarB, u: g)!
            let K = CPace.scalarMultVfy(scalar: scalarA, peerShare: Yb)!
            XCTAssertEqual(K, CPace.scalarMultVfy(scalar: scalarB, peerShare: Ya)!)
            let isk = CPace.deriveISK(sid: sid, k: K, initiatorShare: Ya, initiatorAD: Data(),
                                      responderShare: Yb, responderAD: Data())
            let macKey = CPace.deriveMacKey(sid: sid, isk: isk)
            let ta = CPace.confirmationTag(macKey: macKey, share: Ya, ad: Data())
            let tb = CPace.confirmationTag(macKey: macKey, share: Yb, ad: Data())
            return CPaceVector(
                name: name, description: desc, pin: pin,
                clientSPKIHex: hex(clientSPKI), serverSPKIHex: hex(serverSPKI),
                channelBindingHex: hex(cb), sidHex: hex(sid),
                scalarAHex: hex(scalarA), scalarBHex: hex(scalarB),
                generatorHex: hex(g), shareAHex: hex(Ya), shareBHex: hex(Yb), kHex: hex(K),
                iskHex: hex(isk), macKeyHex: hex(macKey), confirmAHex: hex(ta), confirmBHex: hex(tb))
        }

        let doc = CPaceDoc(
            note: """
            CPace pairing exchange (docs/05). CI = SHA256(clientSPKI(32) ‖ serverSPKI(32)); \
            sid = SHA256(CI); PRS = utf8(PIN); ADa = ADb = "" (empty). \
            g = calculate_generator(PRS, CI, sid) [SHA512 gen-string → first 32 bytes → \
            decodeUCoordinate → Elligator2]. Source is initiator A (ya, Ya), Display is responder \
            B (yb, Yb). K = X25519(ya,Yb) = X25519(yb,Ya) (abort if all-zero). \
            ISK = SHA512(lv_cat("CPace255_ISK", sid, K) ‖ lv_cat(Ya,ADa) ‖ lv_cat(Yb,ADb)). \
            mac_key = SHA512("CPaceMac" ‖ sid ‖ ISK). \
            confirmA/B = HMAC-SHA512(mac_key, lv_cat(share, AD)); compared constant-time. \
            On the wire: PAIR_MSG (type 0x04) carries the 32-byte share; PAIR_CONFIRM (type 0x05) \
            carries the 64-byte tag. Scalars here are fixed test values (SHA256 of a label); a live \
            session uses fresh random scalars. clientSPKI/serverSPKI are fixed patterns, not real certs.
            """,
            ciphersuite: "CPACE-X25519-SHA512-ELLIGATOR2 (draft-irtf-cfrg-cpace-21)",
            vectors: [
                vector("pin_314159", "Reference vector with PIN 314159.", pin: "314159"),
                vector("pin_000000", "Same channel binding, PIN 000000 — proves PIN sensitivity.", pin: "000000"),
            ])
        Vectors.sync("pairing-vectors.json", doc)
    }
}
