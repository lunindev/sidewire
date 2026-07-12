import Foundation
import Crypto

/// The channel-bound PIN proof run once, before HELLO, on a first-time pairing connection
/// (docs/05). It proves — without ever sending the PIN or anything derived from it that a
/// passive/active attacker could use — that both endpoints of *this specific TLS channel*
/// hold the same 6-digit PIN. That binding is what defeats a pairing-time MITM: an attacker
/// terminating TLS sees a different pair of leaf certificates than the honest endpoints, so
/// its channel-binding value differs and the HMAC proof cannot verify across it.
///
/// ## Byte-exact definition (for the Rust client)
/// Let `clientSPKI` and `serverSPKI` be the 32-byte SHA-256 SPKI fingerprints (see
/// `LocalIdentity.spkiHash`) of the **client** (the dialing Source) and **server** (the
/// listening Display) leaf certificates respectively.
///
/// 1. `channelBinding = SHA256( clientSPKI(32 bytes) ‖ serverSPKI(32 bytes) )`  → 32 bytes
///    (order is always client-then-server, independent of who is computing it).
/// 2. `K = HKDF-SHA256(IKM = utf8(PIN), salt = "sidewire-pairing-v2", info = channelBinding, L = 32)`
/// 3. `clientProof = HMAC-SHA256(K, "sidewire-client-proof")`  (32 bytes) — the Source sends this first.
///    `serverProof = HMAC-SHA256(K, "sidewire-server-proof")`  (32 bytes) — the Display replies with this.
///
/// The `deviceId` (advertised in HELLO) is `first16(SPKI)` and thus already bound into the
/// proof through the channel binding, so it needs no separate HMAC input.
///
/// > **Channel binding note:** the design target was RFC 8446 exported keying material (EKM).
/// > Network.framework does not reliably expose the TLS exporter via public API at a point
/// > where both peers can run the proof (`sec_protocol_metadata_create_secret` returns
/// > inconsistent/nil results inside the verify block, which runs mid-handshake, and there is
/// > no supported post-handshake metadata accessor on `NWConnection`). We therefore use the
/// > documented fallback: channel binding over **both leaf-certificate SPKI hashes**, which is
/// > captured reliably in the verify block and is equally MITM-binding for this threat model.
public enum PairingProof {
    /// HKDF salt. Bumped from v1's "sidewire-pairing-v1" (which derived a TLS-PSK directly).
    public static let salt = Data("sidewire-pairing-v2".utf8)
    /// HMAC message for the Source's (client's) proof.
    public static let clientLabel = Data("sidewire-client-proof".utf8)
    /// HMAC message for the Display's (server's) proof.
    public static let serverLabel = Data("sidewire-server-proof".utf8)

    /// `SHA256(clientSPKI ‖ serverSPKI)` — always client (Source) first, server (Display) second.
    public static func channelBinding(clientSPKI: Data, serverSPKI: Data) -> Data {
        var input = Data(capacity: 64)
        input.append(clientSPKI)
        input.append(serverSPKI)
        return Data(SHA256.hash(data: input))
    }

    /// Derive the 32-byte pairing key from the PIN and the channel binding.
    public static func deriveKey(pin: String, channelBinding: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(pin.utf8)),
            salt: salt,
            info: channelBinding,
            outputByteCount: 32)
    }

    /// The 32-byte proof for a given role's label.
    public static func proof(key: SymmetricKey, label: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: label, using: key))
    }

    /// Constant-time comparison of a received proof against the expected value.
    public static func verify(_ received: Data, key: SymmetricKey, label: Data) -> Bool {
        let expected = proof(key: key, label: label)
        return constantTimeEquals(received, expected)
    }

    private static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}
