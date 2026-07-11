import Foundation
import CryptoKit
import SidewireCore

/// Pairing crypto. The stream is TLS-PSK encrypted; the pre-shared key is derived from a
/// 6-digit PIN via HKDF, so the PIN itself never travels on the wire. A peer that doesn't
/// know the PIN cannot complete the TLS handshake (so it can't connect or inject input).
///
/// Note: a 6-digit PIN is low-entropy, so a captured handshake is offline-brute-forceable.
/// That's acceptable for a trusted LAN/Thunderbolt link; the planned hardening is to
/// upgrade to a stored strong per-peer key after first pairing (and/or a PAKE).
enum Pairing {
    private static let pinKey = "sidewire.pairingPIN"

    /// Derive the 32-byte PSK from the pairing PIN.
    static func pskKey(pin: String) -> Data {
        let ikm = SymmetricKey(data: Data(pin.utf8))
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: Data("sidewire-pairing-v1".utf8),
            info: Data("psk".utf8),
            outputByteCount: 32)
        return derived.withUnsafeBytes { Data($0) }
    }

    static func credential(pin: String) -> PSKCredential {
        PSKCredential(key: pskKey(pin: pin), identity: "sidewire")
    }

    static func randomPIN() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    /// This Mac's own PIN (as a Display), generated once and persisted.
    static var localPIN: String {
        if let p = UserDefaults.standard.string(forKey: pinKey), p.count == 6 { return p }
        let p = randomPIN()
        UserDefaults.standard.set(p, forKey: pinKey)
        return p
    }
}
