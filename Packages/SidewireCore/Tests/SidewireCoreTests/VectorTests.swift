import XCTest
import Crypto
@testable import SidewireCore
import SidewireProtocol

private struct PairingVector: Codable, Equatable {
    let name: String
    let description: String
    let pin: String
    let clientSPKIHex: String
    let serverSPKIHex: String
    let saltAscii: String
    let clientLabelAscii: String
    let serverLabelAscii: String
    let channelBindingHex: String
    let keyHex: String
    let clientProofHex: String
    let serverProofHex: String
}
private struct PairingDoc: Codable, Equatable {
    let note: String
    let vectors: [PairingVector]
}

/// Deterministic golden vectors for the channel-bound PIN proof (docs/05). A foreign client
/// derives K + the two proofs from a fixed (PIN, clientSPKI, serverSPKI) and must match these.
final class VectorTests: XCTestCase {

    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    private func keyHex(_ k: SymmetricKey) -> String { hex(k.withUnsafeBytes { Data($0) }) }

    func testPairingVectors() {
        // Fixed, well-known SPKI fingerprints (32 bytes each) so the vectors are reproducible.
        let clientSPKI = Data((0x00...0x1F).map { UInt8($0) })  // 00 01 … 1f
        let serverSPKI = Data((0x20...0x3F).map { UInt8($0) })  // 20 21 … 3f

        func vector(_ name: String, _ desc: String, pin: String) -> PairingVector {
            let cb = PairingProof.channelBinding(clientSPKI: clientSPKI, serverSPKI: serverSPKI)
            let key = PairingProof.deriveKey(pin: pin, channelBinding: cb)
            let clientProof = PairingProof.proof(key: key, label: PairingProof.clientLabel)
            let serverProof = PairingProof.proof(key: key, label: PairingProof.serverLabel)
            return PairingVector(
                name: name, description: desc, pin: pin,
                clientSPKIHex: hex(clientSPKI), serverSPKIHex: hex(serverSPKI),
                saltAscii: String(decoding: PairingProof.salt, as: UTF8.self),
                clientLabelAscii: String(decoding: PairingProof.clientLabel, as: UTF8.self),
                serverLabelAscii: String(decoding: PairingProof.serverLabel, as: UTF8.self),
                channelBindingHex: hex(cb), keyHex: keyHex(key),
                clientProofHex: hex(clientProof), serverProofHex: hex(serverProof))
        }

        let doc = PairingDoc(
            note: """
            Channel-bound PIN proof (docs/05). channelBinding = SHA256(clientSPKI(32) ‖ serverSPKI(32)); \
            K = HKDF-SHA256(IKM=utf8(PIN), salt=saltAscii, info=channelBinding, L=32); \
            clientProof = HMAC-SHA256(K, clientLabelAscii); serverProof = HMAC-SHA256(K, serverLabelAscii). \
            On the wire: PAIR_PROOF (type 0x04) carries the 32-byte proof; PAIR_ACK (type 0x05) is empty. \
            Proof comparisons MUST be constant-time. clientSPKI/serverSPKI here are fixed test patterns, \
            not real certificates.
            """,
            vectors: [
                vector("pin_314159", "Reference vector with PIN 314159.", pin: "314159"),
                vector("pin_000000", "Same channel binding, PIN 000000 — proves PIN sensitivity.", pin: "000000"),
            ])
        Vectors.sync("pairing-vectors.json", doc)
    }
}
