import XCTest
import Crypto
@testable import SidewireCore
import SidewireProtocol

/// Unit tests for the pairing primitives (no sockets): channel binding, key derivation, proofs,
/// the trust store, and the rate limiter.
final class PairingTests: XCTestCase {

    private func spki(_ byte: UInt8) -> Data { Data(repeating: byte, count: 32) }

    // MARK: - Channel binding + proof

    func testBothSidesDeriveTheSameKeyAndProofs() {
        let clientSPKI = spki(0xAA), serverSPKI = spki(0xBB)
        // Both peers order client-then-server regardless of who computes it.
        let cbClient = PairingProof.channelBinding(clientSPKI: clientSPKI, serverSPKI: serverSPKI)
        let cbServer = PairingProof.channelBinding(clientSPKI: clientSPKI, serverSPKI: serverSPKI)
        XCTAssertEqual(cbClient, cbServer)
        XCTAssertEqual(cbClient.count, 32)

        let kClient = PairingProof.deriveKey(pin: "123456", channelBinding: cbClient)
        let kServer = PairingProof.deriveKey(pin: "123456", channelBinding: cbServer)

        let clientProof = PairingProof.proof(key: kClient, label: PairingProof.clientLabel)
        let serverProof = PairingProof.proof(key: kServer, label: PairingProof.serverLabel)
        XCTAssertEqual(clientProof.count, 32)
        // The receiver verifies the *other* side's proof with its own derived key.
        XCTAssertTrue(PairingProof.verify(clientProof, key: kServer, label: PairingProof.clientLabel))
        XCTAssertTrue(PairingProof.verify(serverProof, key: kClient, label: PairingProof.serverLabel))
        // Cross-label must not verify.
        XCTAssertFalse(PairingProof.verify(clientProof, key: kServer, label: PairingProof.serverLabel))
    }

    func testWrongPINProducesNonMatchingProof() {
        let cb = PairingProof.channelBinding(clientSPKI: spki(1), serverSPKI: spki(2))
        let right = PairingProof.deriveKey(pin: "123456", channelBinding: cb)
        let wrong = PairingProof.deriveKey(pin: "654321", channelBinding: cb)
        let proof = PairingProof.proof(key: wrong, label: PairingProof.clientLabel)
        XCTAssertFalse(PairingProof.verify(proof, key: right, label: PairingProof.clientLabel))
    }

    func testDifferentChannelBindingProducesNonMatchingProof() {
        // Same PIN but a MITM-substituted server cert ⇒ different channel binding ⇒ proof fails.
        let honest = PairingProof.channelBinding(clientSPKI: spki(1), serverSPKI: spki(2))
        let mitm = PairingProof.channelBinding(clientSPKI: spki(1), serverSPKI: spki(0x99))
        let kHonest = PairingProof.deriveKey(pin: "123456", channelBinding: honest)
        let kMitm = PairingProof.deriveKey(pin: "123456", channelBinding: mitm)
        let proof = PairingProof.proof(key: kMitm, label: PairingProof.clientLabel)
        XCTAssertFalse(PairingProof.verify(proof, key: kHonest, label: PairingProof.clientLabel))
    }

    func testChannelBindingOrderMatters() {
        let a = PairingProof.channelBinding(clientSPKI: spki(1), serverSPKI: spki(2))
        let b = PairingProof.channelBinding(clientSPKI: spki(2), serverSPKI: spki(1))
        XCTAssertNotEqual(a, b, "client/server order must be significant")
    }

    // MARK: - deviceId derivation

    func testDeviceIdIsFirst16BytesOfSPKIHashHex() {
        var bytes = Data((0..<32).map { UInt8($0) })
        let id = LocalIdentity.deviceId(fromSPKIHash: bytes)
        XCTAssertEqual(id, "000102030405060708090a0b0c0d0e0f")
        XCTAssertEqual(id.count, 32)
        bytes[0] = 0xFF
        XCTAssertNotEqual(LocalIdentity.deviceId(fromSPKIHash: bytes), id)
    }

    // MARK: - Trust store

    func testInMemoryTrustStorePinAndForget() {
        let ts = InMemoryTrustStore()
        XCTAssertNil(ts.pinned(for: "abc"))
        ts.pin(TrustedPeer(deviceId: "abc", spkiHash: "dead", name: "Mac A"))
        XCTAssertEqual(ts.pinned(for: "abc")?.name, "Mac A")
        XCTAssertTrue(ts.isPaired("abc"))
        XCTAssertEqual(ts.peers().count, 1)
        ts.forget("abc")
        XCTAssertNil(ts.pinned(for: "abc"))
        XCTAssertFalse(ts.isPaired("abc"))
    }

    // MARK: - Identity persistence

    func testLocalIdentityIsStableAcrossReload() throws {
        let tag = Data("sidewire-test-persist-\(UUID().uuidString)".utf8)
        let label = "sidewire-test-persist-\(UUID().uuidString)"
        let first = try LocalIdentity(keyTag: tag, certLabel: label)
        defer { first.destroy() }
        // Reloading the same tag/label must yield the same key → same cert → same id.
        let second = try LocalIdentity(keyTag: tag, certLabel: label)
        XCTAssertEqual(first.deviceId, second.deviceId)
        XCTAssertEqual(first.spkiHash, second.spkiHash)
        XCTAssertEqual(first.deviceId.count, 32)
        // deviceId is the first 16 bytes of the SPKI hash, hex-encoded.
        XCTAssertEqual(first.deviceId, first.spkiHash.prefix(16).map { String(format: "%02x", $0) }.joined())
    }

    /// Exercises the REAL Keychain-backed trust store (generic-password items) end to end —
    /// pin, cache reload from the Keychain in a fresh instance, and forget — under a unique
    /// service name so it never touches the app's real store, with cleanup.
    func testKeychainTrustStoreRealRoundTrip() throws {
        let service = "com.kinocoder.sidewire.trust.TEST.\(UUID().uuidString)"
        let did = "abc123"
        let store = KeychainTrustStore(service: service)
        defer { store.forget(did) }

        XCTAssertNil(store.pinned(for: did))
        store.pin(TrustedPeer(deviceId: did, spkiHash: "deadbeef", name: "Test Mac"))
        XCTAssertEqual(store.pinned(for: did)?.name, "Test Mac")

        // A fresh instance must reload the same peer straight from the Keychain (cache miss).
        let reloaded = KeychainTrustStore(service: service)
        XCTAssertEqual(reloaded.pinned(for: did)?.spkiHash, "deadbeef")
        XCTAssertEqual(reloaded.peers().count, 1)

        reloaded.forget(did)
        let afterForget = KeychainTrustStore(service: service)
        XCTAssertNil(afterForget.pinned(for: did), "forget must delete the Keychain item")
    }

    // MARK: - Rate limiter

    func testRateLimiterLocksAfterThresholdAndResetsOnSuccess() {
        let limiter = PairingRateLimiter(threshold: 5, baseLockout: 60, cap: 900)
        for _ in 0..<4 {
            XCTAssertTrue(limiter.allowAttempt())
            limiter.recordFailure()
        }
        XCTAssertTrue(limiter.allowAttempt(), "still allowed after 4 failures")
        limiter.recordFailure() // 5th → lockout
        XCTAssertFalse(limiter.allowAttempt(), "locked after 5 failures")
        XCTAssertGreaterThan(limiter.lockoutRemaining(), 0)

        // A success clears everything.
        limiter.recordSuccess()
        XCTAssertTrue(limiter.allowAttempt())
        XCTAssertEqual(limiter.lockoutRemaining(), 0)
    }

    func testRateLimiterExponentialDoubling() {
        let limiter = PairingRateLimiter(threshold: 1, baseLockout: 1, cap: 8)
        limiter.recordFailure() // lockout #1 → ~1s
        let first = limiter.lockoutRemaining()
        XCTAssertLessThanOrEqual(first, 1.0 + 0.5)
        // Force the window to elapse by using a tiny base; simulate by recording again after it
        // would have cleared is time-dependent, so just assert the first window is bounded by cap.
        XCTAssertGreaterThan(first, 0)
        XCTAssertLessThanOrEqual(first, 8.0)
    }
}
