import Foundation
import Crypto

/// CPace — a balanced PAKE — run once, before HELLO, on a first-time pairing connection (docs/05).
/// It replaces the Phase-7a channel-bound HMAC PIN proof. Where the HMAC proof only stopped a
/// pairing-time MITM from *relaying* a proof (an on-path attacker could still offline-guess the
/// 6-digit PIN from a captured proof), CPace makes **every PIN guess cost one online interaction**:
/// a wrong PIN yields an unrelated shared secret and the key-confirmation MAC simply fails. The
/// Display's rate limiter then bounds those online guesses. This is what moves "active MITM at
/// pairing time" from residual-risk to in-scope-defended.
///
/// ## Ciphersuite: CPACE-X25519-SHA512-ELLIGATOR2 (`draft-irtf-cfrg-cpace-21`, April 2026)
/// - Group `G_X25519`: `DSI = "CPace255"`, `DSI_ISK = "CPace255_ISK"`, `field_size_bytes = 32`,
///   `scalar_mult = scalar_mult_vfy = X25519` (RFC 7748), identity `I = 0³²`.
/// - Hash `SHA-512`: `s_in_bytes = 128` (input block size), `b_in_bytes = 64`.
/// - The one custom primitive is the Elligator2 map-to-curve (`Elligator2` + `Field25519`);
///   everything else (X25519, SHA-512, HMAC) is swift-crypto.
///
/// ## Sidewire bindings (what a Rust peer must match)
/// - `PRS` (password) = `utf8(PIN)`.
/// - `CI`  (channel identifier) = the 32-byte TLS **channelBinding** = `SHA256(clientSPKI‖serverSPKI)`.
///   Using it as `CI` binds the PAKE to this exact TLS channel — a relay MITM has a different
///   channelBinding and cannot complete the exchange.
/// - `sid` (session id) = `SHA256(channelBinding)` (32 bytes). Deterministic — both peers already
///   share channelBinding, so no `sid` exchange is needed. Per-run key freshness comes from the
///   fresh random scalars, not from `sid`.
/// - Roles: the **Source is the CPace initiator (A)**, the **Display is the responder (B)** — the
///   Source always sends its share first (docs/05). Associated data `ADa = ADb = ""` (empty): the
///   deviceIds are already bound through `CI`.
/// - Transcript ordering: initiator-responder (`transcript_ir`), i.e. `lv_cat(Ya,ADa)‖lv_cat(Yb,ADb)`.
/// - Key confirmation (draft §10.4): `mac_key = SHA512("CPaceMac"‖sid‖ISK)`;
///   each party sends `MAC = HMAC-SHA512(mac_key, lv_cat(ownShare, ownAD))` and verifies the peer's
///   (constant-time). This is the message where a wrong PIN fails.
///
/// Verified byte-for-byte against the draft's published X25519/SHA-512 test vectors
/// (generator, shares, K, ISK) — see `CPaceVectorTests`.
enum CPace {
    static let dsi = Data("CPace255".utf8)
    static let dsiISK = Data("CPace255_ISK".utf8)
    /// SHA-512 input block size, in bytes (the zero-pad target in `generator_string`).
    static let sInBytes = 128
    /// X25519 field/element size.
    static let elementBytes = 32
    static let macPrefix = Data("CPaceMac".utf8)

    // MARK: - Channel binding + sid

    /// `SHA256(clientSPKI ‖ serverSPKI)` — always client (Source) first, server (Display) second.
    /// (Unchanged from Phase 7a; the value CPace uses as its `CI`.)
    static func channelBinding(clientSPKI: Data, serverSPKI: Data) -> Data {
        var input = Data(capacity: clientSPKI.count + serverSPKI.count)
        input.append(clientSPKI)
        input.append(serverSPKI)
        return Data(SHA256.hash(data: input))
    }

    /// `sid = SHA256(channelBinding)` (32 bytes). Deterministic; both peers derive it identically.
    static func sid(channelBinding: Data) -> Data {
        Data(SHA256.hash(data: channelBinding))
    }

    // MARK: - String utilities (draft §A.1)

    /// LEB128 length prefix followed by the data (`prepend_len`).
    static func prependLen(_ data: Data) -> Data {
        var out = Data()
        var length = data.count
        repeat {
            if length < 128 {
                out.append(UInt8(length))
            } else {
                out.append(UInt8((length & 0x7F) + 0x80))
            }
            length >>= 7
        } while length != 0
        out.append(data)
        return out
    }

    /// Length-prefixed concatenation (`lv_cat`).
    static func lvCat(_ parts: [Data]) -> Data {
        var out = Data()
        for p in parts { out.append(prependLen(p)) }
        return out
    }

    // MARK: - Generator (draft §8.1 / §8.2)

    /// `generator_string(DSI, PRS, CI, sid, s_in_bytes)` with the zero padding that fills the first
    /// hash block.
    static func generatorString(prs: Data, ci: Data, sid: Data) -> Data {
        let zpad = max(0, sInBytes - prependLen(prs).count - prependLen(dsi).count - 1)
        return lvCat([dsi, prs, Data(repeating: 0, count: zpad), ci, sid])
    }

    /// `g = calculate_generator(H, PRS, CI, sid)`: hash the generator string, take the first 32
    /// bytes, apply `decodeUCoordinate` (clear bit #255), then Elligator2-map to a u-coordinate.
    static func calculateGenerator(pin: String, ci: Data, sid: Data) -> [UInt8] {
        let gen = generatorString(prs: Data(pin.utf8), ci: ci, sid: sid)
        let full = SHA512.hash(data: gen)
        var u = Array(full.prefix(elementBytes)) // gen_str_hash = H.hash(gen, field_size_bytes)
        u[31] &= 0x7F                            // decodeUCoordinate(·, 255): clear bit #255
        return Elligator2.map(fieldBytes: u)
    }

    // MARK: - Scalar multiplication (X25519, via swift-crypto)

    /// A fresh CPace scalar: `sample_random_bytes(32)`. X25519 clamps internally, so no masking is
    /// applied here (per the draft's `G_X25519.sample_scalar`).
    static func sampleScalar() -> [UInt8] {
        var s = [UInt8](repeating: 0, count: elementBytes)
        for i in 0..<elementBytes { s[i] = UInt8.random(in: 0...255) }
        return s
    }

    /// `X25519(scalar, u)` — our own share `Ya = scalar_mult(ya, g)`. Returns nil only if the
    /// primitive fails (e.g. `g` were a low-order point — negligible for an honest generator).
    static func scalarMult(scalar: [UInt8], u: [UInt8]) -> [UInt8]? {
        x25519(scalar: scalar, u: u, rejectIdentity: false)
    }

    /// `scalar_mult_vfy(scalar, peerShare)` for the shared secret `K`. Returns nil (→ abort) if the
    /// result is the identity `I = 0³²` — i.e. the peer sent a low-order point — as the draft
    /// mandates ("MUST abort if K = G.I").
    static func scalarMultVfy(scalar: [UInt8], peerShare: [UInt8]) -> [UInt8]? {
        x25519(scalar: scalar, u: peerShare, rejectIdentity: true)
    }

    private static func x25519(scalar: [UInt8], u: [UInt8], rejectIdentity: Bool) -> [UInt8]? {
        guard scalar.count == elementBytes, u.count == elementBytes else { return nil }
        do {
            let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(scalar))
            let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(u))
            let secret = try priv.sharedSecretFromKeyAgreement(with: pub)
            let bytes = secret.withUnsafeBytes { Array($0) }
            // Defence in depth: reject the all-zero result even if the primitive did not throw.
            if rejectIdentity, bytes.allSatisfy({ $0 == 0 }) { return nil }
            return bytes
        } catch {
            // swift-crypto throws for a key-agreement result that is the point at infinity
            // (a low-order peer point) — exactly the abort condition, so treat it as such.
            return nil
        }
    }

    // MARK: - ISK + key confirmation (draft §7.2 / §10.4)

    /// `ISK = H(lv_cat(DSI_ISK, sid, K) ‖ transcript_ir(Ya,ADa,Yb,ADb))`, initiator (A) first.
    static func deriveISK(sid: Data, k: [UInt8],
                          initiatorShare: [UInt8], initiatorAD: Data,
                          responderShare: [UInt8], responderAD: Data) -> Data {
        var m = lvCat([dsiISK, sid, Data(k)])
        m.append(lvCat([Data(initiatorShare), initiatorAD]))
        m.append(lvCat([Data(responderShare), responderAD]))
        return Data(SHA512.hash(data: m))
    }

    /// `mac_key = H("CPaceMac" ‖ sid ‖ ISK)` (64 bytes).
    static func deriveMacKey(sid: Data, isk: Data) -> Data {
        var m = Data()
        m.append(macPrefix)
        m.append(sid)
        m.append(isk)
        return Data(SHA512.hash(data: m))
    }

    /// A party's confirmation tag `MAC(mac_key, lv_cat(ownShare, ownAD))` — HMAC-SHA512.
    static func confirmationTag(macKey: Data, share: [UInt8], ad: Data) -> Data {
        let msg = lvCat([Data(share), ad])
        return Data(HMAC<SHA512>.authenticationCode(for: msg, using: SymmetricKey(data: macKey)))
    }

    /// Constant-time comparison of a received confirmation tag against the expected value.
    static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}
