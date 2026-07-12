import Foundation

/// Pairing PIN storage & generation. In protocol v2 the PIN is no longer used to derive a
/// TLS-PSK; it is the low-entropy secret (`PRS`) for the **CPace PAKE** run over an already-
/// established certificate-based TLS 1.3 channel (see `SidewireCore.CPace` / docs/05). The PIN
/// itself never crosses the wire — only CPace public shares and a key-confirmation MAC do, and a
/// wrong PIN yields an unrelated shared secret (each guess costs one online, rate-limited attempt).
///
/// After the first successful pairing, the peer's public key is stored in the Keychain trust
/// store (`SidewireCore.TrustStore`) and subsequent connections skip the PIN entirely; the PIN
/// is only needed to pair (or re-pair) a Mac.
enum Pairing {
    private static let pinKey = "sidewire.pairingPIN"

    static func randomPIN() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    /// This Mac's own PIN (as a Display), generated once and persisted (stable across launches so
    /// a Source pairs once). Rotate on demand with `rotateLocalPIN()`.
    static var localPIN: String {
        if let p = UserDefaults.standard.string(forKey: pinKey), p.count == 6 { return p }
        let p = randomPIN()
        UserDefaults.standard.set(p, forKey: pinKey)
        return p
    }

    /// Generate a fresh local PIN and persist it, returning the new value. Only affects FUTURE
    /// pairings — already-paired Sources keep working via the stored trust-store key and never
    /// need the new PIN unless they are forgotten and must re-pair.
    @discardableResult
    static func rotateLocalPIN() -> String {
        let p = randomPIN()
        UserDefaults.standard.set(p, forKey: pinKey)
        return p
    }
}
