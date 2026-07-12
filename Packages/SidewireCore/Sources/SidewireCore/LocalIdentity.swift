import Foundation
import Security
import Crypto
import X509
import SwiftASN1

/// This device's long-lived cryptographic identity for certificate-based TLS 1.3 (docs/05,
/// docs/09 §D11). A persistent P-256 key pair + a minimal self-signed X.509 certificate,
/// stored in the Keychain, from which we mint a `SecIdentity` → `sec_identity_t` for
/// Network.framework's `sec_protocol_options_set_local_identity`.
///
/// ## Why this shape (portability for the Rust client)
/// - Curve: **NIST P-256** (secp256r1). Signature: **ECDSA-with-SHA256**.
/// - The certificate is self-signed and effectively an opaque key carrier: no CA, no
///   hostname, `notBefore = now-1h`, `notAfter = now+20y`, subject == issuer == `CN=Sidewire`.
///   Peers never validate the chain at the TLS layer — trust comes from the pinned public key
///   + the CPace PAKE (see `TLS.swift` / `CPace.swift`).
/// - `spkiHash` = **SHA-256 over the DER `SubjectPublicKeyInfo`** (RFC 7469 "SPKI Fingerprint";
///   for P-256 the SPKI is the standard 91-byte `SEQUENCE { AlgorithmIdentifier, BIT STRING }`
///   that swift-crypto's `P256.Signing.PublicKey.derRepresentation` and OpenSSL `i2d_PUBKEY`
///   both produce). This is the value pinned in the trust store.
/// - `deviceId` = the **first 16 bytes of `spkiHash`, lowercase hex** (32 chars). The device
///   identity is therefore *self-authenticating*: a peer cannot claim a `deviceId` without
///   holding the matching private key, because the id is derived from the key. This is what
///   binds the wire `deviceId` (in HELLO) to the pinned key and lets pinning be keyed by id.
///
/// ## Keychain mechanics
/// The private key is generated **directly in the Keychain** via `SecKeyCreateRandomKey`
/// (`isPermanent: true`). swift-certificates signs the self-signed cert *through* that
/// `SecKey` (`Certificate.PrivateKey(_ secKey:)` → `SecKeyWrapper`), so the raw private key is
/// never exported. `SecIdentityCreateWithCertificate` then re-pairs the stored cert with its
/// in-Keychain key. (Importing an *externally*-generated `SecKey` via `SecItemAdd` fails with
/// `errSecMissingEntitlement` in an unsigned process — generating in-place avoids that and
/// works in both the signed app and the unsigned test bundle.)
public final class LocalIdentity: @unchecked Sendable {
    public let secIdentity: SecIdentity
    /// SHA-256 over the DER SubjectPublicKeyInfo (32 bytes) — the pinned fingerprint.
    public let spkiHash: Data
    /// First 16 bytes of `spkiHash` as lowercase hex (32 chars). Advertised in HELLO.
    public let deviceId: String
    /// The leaf certificate DER (handy for tests / diagnostics).
    public let certificateDER: Data

    private let keyTag: Data
    private let certLabel: String

    /// The app-wide singleton identity, generated once and reused across launches.
    public static let shared: LocalIdentity = {
        do {
            return try LocalIdentity(keyTag: Data(LocalIdentity.defaultKeyTag.utf8),
                                     certLabel: LocalIdentity.defaultCertLabel)
        } catch {
            coreLog.fault("LocalIdentity.shared failed: \(String(describing: error), privacy: .public)")
            // A device with no usable identity cannot connect; fail loudly rather than limp on.
            fatalError("Sidewire could not create its device identity: \(error)")
        }
    }()

    static let defaultKeyTag = "com.kinocoder.sidewire.identity.key"
    static let defaultCertLabel = "Sidewire Device Identity"

    /// Load the identity for `keyTag`/`certLabel`, creating (and persisting) it on first use.
    public init(keyTag: Data, certLabel: String) throws {
        self.keyTag = keyTag
        self.certLabel = certLabel

        let key = try Self.loadOrCreateKey(tag: keyTag)
        let (secCert, der) = try Self.loadOrCreateCertificate(key: key, label: certLabel)
        self.certificateDER = der

        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, secCert, &identity)
        guard status == errSecSuccess, let identity else {
            throw IdentityError.identityCreation(status)
        }
        self.secIdentity = identity

        // SPKI hash from the certificate's public key (same value a peer computes from the leaf).
        guard let spki = Self.spkiHash(fromCertificateDER: der) else {
            throw IdentityError.spkiExtraction
        }
        self.spkiHash = spki
        self.deviceId = Self.deviceId(fromSPKIHash: spki)
    }

    /// A fresh throwaway identity (unique tag) for tests. Call `destroy()` to remove its
    /// Keychain items afterwards.
    public static func ephemeral(label: String = "sidewire-test-\(UUID().uuidString)") throws -> LocalIdentity {
        try LocalIdentity(keyTag: Data(label.utf8), certLabel: label)
    }

    /// Remove this identity's Keychain items (test cleanup; no-op-safe if already gone).
    public func destroy() {
        SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: keyTag] as CFDictionary)
        SecItemDelete([kSecClass: kSecClassCertificate, kSecAttrLabel: certLabel] as CFDictionary)
    }

    /// A fresh `sec_identity_t` for one TLS connection.
    public func makeSecIdentityT() -> sec_identity_t? {
        sec_identity_create(secIdentity)
    }

    // MARK: - Key

    private static func loadOrCreateKey(tag: Data) throws -> SecKey {
        // Try to load an existing permanent key.
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecSuccess, let key = out {
            // Force-cast is safe: kSecClassKey + kSecReturnRef yields a SecKey.
            return (key as! SecKey)
        }

        // Create a new permanent key in-place (avoids the errSecMissingEntitlement that a
        // SecItemAdd of an externally-created key hits in an unsigned process).
        var err: Unmanaged<CFError>?
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrLabel as String: "Sidewire Identity Key",
            ],
        ]
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &err) else {
            throw IdentityError.keyGeneration(err?.takeRetainedValue())
        }
        return key
    }

    // MARK: - Certificate

    private static func loadOrCreateCertificate(key: SecKey, label: String) throws -> (SecCertificate, Data) {
        // A previously stored cert for this identity?
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
        ]
        var out: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let existing = out {
            let cert = existing as! SecCertificate
            let der = SecCertificateCopyData(cert) as Data
            return (cert, der)
        }

        // Build a fresh self-signed certificate signed via the Keychain SecKey.
        let der = try buildSelfSignedCertificate(key: key)
        guard let secCert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw IdentityError.certificateParse
        }
        let add: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: secCert,
            kSecAttrLabel as String: label,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        // errSecDuplicateItem is fine (a concurrent creation won the race).
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw IdentityError.certificateStore(status)
        }
        return (secCert, der)
    }

    private static func buildSelfSignedCertificate(key: SecKey) throws -> Data {
        let privateKey = try Certificate.PrivateKey(key)          // signs via SecKeyWrapper
        let publicKey = privateKey.publicKey
        let name = try DistinguishedName { CommonName("Sidewire") }
        let now = Date()
        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: publicKey,
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(60 * 60 * 24 * 365 * 20),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                KeyUsage(digitalSignature: true)
            },
            issuerPrivateKey: privateKey)
        var serializer = DER.Serializer()
        try serializer.serialize(cert)
        return Data(serializer.serializedBytes)
    }

    // MARK: - SPKI / deviceId helpers

    /// SHA-256 over the DER SubjectPublicKeyInfo of a certificate's public key.
    static func spkiHash(fromCertificateDER der: Data) -> Data? {
        guard let cert = try? Certificate(derEncoded: Array(der)),
              let p256 = P256.Signing.PublicKey(cert.publicKey) else { return nil }
        return Data(SHA256.hash(data: p256.derRepresentation))
    }

    /// SHA-256 SPKI fingerprint of a leaf certificate presented by a peer during TLS.
    /// Uses the same computation as `spkiHash(fromCertificateDER:)` (via the raw EC point →
    /// swift-crypto SPKI DER) so both sides agree byte-for-byte.
    public static func spkiHash(fromLeaf secCert: SecCertificate) -> Data? {
        guard let secKey = SecCertificateCopyKey(secCert) else { return nil }
        var err: Unmanaged<CFError>?
        guard let point = SecKeyCopyExternalRepresentation(secKey, &err) as Data?,
              let p256 = try? P256.Signing.PublicKey(x963Representation: point) else { return nil }
        return Data(SHA256.hash(data: p256.derRepresentation))
    }

    /// Derive the stable, self-authenticating device id from an SPKI hash: first 16 bytes, hex.
    public static func deviceId(fromSPKIHash hash: Data) -> String {
        hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public enum IdentityError: Error {
        case keyGeneration(CFError?)
        case certificateParse
        case certificateStore(OSStatus)
        case identityCreation(OSStatus)
        case spkiExtraction
    }
}

extension Data {
    /// Lowercase hex encoding — used for SPKI hashes / device ids in the trust store and logs.
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
