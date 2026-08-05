import XCTest
import Security
@testable import SidewireCore

/// Guards the Keychain against the leak that made `trustd` unusable.
///
/// Every `LocalIdentity` used to add a permanent self-signed certificate to the login keychain,
/// because the load-or-create lookup was keyed on `kSecAttrLabel` — an attribute macOS derives
/// from the subject common name for certificate items and does not take from the caller. The
/// lookup therefore never matched, a fresh certificate was minted and stored on every single
/// initialisation, and `destroy()` (deleting by the same never-present label) removed none of it.
///
/// The consequence was not clutter. Hundreds of self-signed certificates sharing a subject turn
/// chain building into a backtracking search with one ECDSA P-256 verification per candidate:
/// `trustd` saturates a core and every `SecTrust` consumer on the machine queues behind it.
final class KeychainHygieneTests: XCTestCase {

    private var bag: IdentityBag!
    override func setUp() { super.setUp(); bag = IdentityBag() }
    override func tearDown() { bag.destroyAll(); super.tearDown() }

    /// The invariant: minting identities must not add certificates to the Keychain. At all.
    func testCreatingIdentitiesStoresNoCertificates() throws {
        let before = LocalIdentity.storedCertificateCount()

        for _ in 0..<5 { _ = try bag.make() }

        let after = LocalIdentity.storedCertificateCount()
        XCTAssertEqual(after, before,
                       "creating identities must not store certificates — \(after - before) leaked")
    }

    /// Re-creating the *same* identity must be idempotent. This is the app's own path: the
    /// singleton is rebuilt on every launch from the same persistent key, and used to add a new
    /// certificate each time because the lookup could not find the previous one.
    func testReinitialisingTheSameIdentityIsIdempotent() throws {
        let label = "sidewire-test-idempotent-\(UUID().uuidString)"
        let tag = Data(label.utf8)
        defer { SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: tag] as CFDictionary) }

        let before = LocalIdentity.storedCertificateCount()
        let first = try LocalIdentity(keyTag: tag, certLabel: label)
        let second = try LocalIdentity(keyTag: tag, certLabel: label)
        let after = LocalIdentity.storedCertificateCount()

        XCTAssertEqual(after, before, "re-initialising an identity must not store anything")
        // The key is reused, so the pinned fingerprint and the device id stay stable across
        // launches even though the certificate itself is freshly minted each time. This is what
        // makes not storing the certificate safe: peers pin the SPKI, never the leaf.
        XCTAssertEqual(first.spkiHash, second.spkiHash, "the persistent key must be reused")
        XCTAssertEqual(first.deviceId, second.deviceId, "the device id must be stable across launches")
    }

    /// `destroy()` must actually remove the key, and must report honestly whether it did.
    func testDestroyRemovesTheKeyAndReportsIt() throws {
        let identity = try LocalIdentity.ephemeral()
        XCTAssertTrue(identity.destroy(), "destroy() must succeed")

        var out: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassKey,
                                          kSecAttrApplicationTag: Data("x".utf8),
                                          kSecReturnRef: true] as CFDictionary, &out)
        XCTAssertNotEqual(status, errSecSuccess, "no stray key should match a bogus tag")
        XCTAssertTrue(identity.destroy(), "destroy() must be safe to call twice")
    }
}
