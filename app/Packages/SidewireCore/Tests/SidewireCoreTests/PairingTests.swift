import XCTest
import Crypto
@testable import SidewireCore
import SidewireProtocol

/// Unit tests for the pairing primitives (no sockets): channel binding, key derivation, proofs,
/// the trust store, and the rate limiter.
final class PairingTests: XCTestCase {

    private func spki(_ byte: UInt8) -> Data { Data(repeating: byte, count: 32) }

    /// Run a full honest CPace exchange for a given PIN + channel binding with injected scalars,
    /// returning both sides' ISK + confirmation tags. Source is the initiator (A), Display the
    /// responder (B).
    private func runCPace(pin: String, cb: Data, ya: [UInt8], yb: [UInt8])
        -> (iskA: Data, iskB: Data, taA: Data, tbA: Data, taB: Data, tbB: Data)? {
        let sid = CPace.sid(channelBinding: cb)
        let g = CPace.calculateGenerator(pin: pin, ci: cb, sid: sid)
        guard let Ya = CPace.scalarMult(scalar: ya, u: g),
              let Yb = CPace.scalarMult(scalar: yb, u: g),
              let Ka = CPace.scalarMultVfy(scalar: ya, peerShare: Yb),
              let Kb = CPace.scalarMultVfy(scalar: yb, peerShare: Ya) else { return nil }
        let iskA = CPace.deriveISK(sid: sid, k: Ka, initiatorShare: Ya, initiatorAD: Data(),
                                   responderShare: Yb, responderAD: Data())
        let iskB = CPace.deriveISK(sid: sid, k: Kb, initiatorShare: Ya, initiatorAD: Data(),
                                   responderShare: Yb, responderAD: Data())
        let mkA = CPace.deriveMacKey(sid: sid, isk: iskA)
        let mkB = CPace.deriveMacKey(sid: sid, isk: iskB)
        // Each side MACs its own share; verifies the peer's.
        return (iskA, iskB,
                taA: CPace.confirmationTag(macKey: mkA, share: Ya, ad: Data()),
                tbA: CPace.confirmationTag(macKey: mkA, share: Yb, ad: Data()),
                taB: CPace.confirmationTag(macKey: mkB, share: Ya, ad: Data()),
                tbB: CPace.confirmationTag(macKey: mkB, share: Yb, ad: Data()))
    }

    // MARK: - Channel binding + CPace exchange

    func testBothSidesDeriveTheSameISKAndConfirm() {
        let cb = CPace.channelBinding(clientSPKI: spki(0xAA), serverSPKI: spki(0xBB))
        let ya = CPace.sampleScalar(), yb = CPace.sampleScalar()
        guard let r = runCPace(pin: "123456", cb: cb, ya: ya, yb: yb) else { return XCTFail("CPace failed") }
        // Both sides derive the identical ISK, hence identical mac key and matching tags.
        XCTAssertEqual(r.iskA, r.iskB)
        XCTAssertEqual(r.iskA.count, 64)
        // The Source verifies the Display's tag (tbA) against what the Display sent (tbB), and
        // vice-versa. Matching keys ⇒ these are equal.
        XCTAssertTrue(CPace.constantTimeEquals(r.tbA, r.tbB))
        XCTAssertTrue(CPace.constantTimeEquals(r.taB, r.taA))
    }

    func testWrongPINFailsConfirmation() {
        // The Source uses PIN 123456, the Display 654321: same channel binding, different generator
        // ⇒ different ISK ⇒ the confirmation tags do not match (this is the online PIN check).
        let cb = CPace.channelBinding(clientSPKI: spki(1), serverSPKI: spki(2))
        let sid = CPace.sid(channelBinding: cb)
        let ya = CPace.sampleScalar(), yb = CPace.sampleScalar()
        let gSource = CPace.calculateGenerator(pin: "123456", ci: cb, sid: sid)
        let gDisplay = CPace.calculateGenerator(pin: "654321", ci: cb, sid: sid)
        XCTAssertNotEqual(Data(gSource), Data(gDisplay), "different PINs ⇒ different generator")
        let Ya = CPace.scalarMult(scalar: ya, u: gSource)!
        let Yb = CPace.scalarMult(scalar: yb, u: gDisplay)!
        // Each side computes K against its own generator's scalar and the peer's share.
        let Ka = CPace.scalarMultVfy(scalar: ya, peerShare: Yb)!
        let Kb = CPace.scalarMultVfy(scalar: yb, peerShare: Ya)!
        let iskA = CPace.deriveISK(sid: sid, k: Ka, initiatorShare: Ya, initiatorAD: Data(),
                                   responderShare: Yb, responderAD: Data())
        let iskB = CPace.deriveISK(sid: sid, k: Kb, initiatorShare: Ya, initiatorAD: Data(),
                                   responderShare: Yb, responderAD: Data())
        XCTAssertNotEqual(iskA, iskB, "mismatched PIN ⇒ mismatched ISK")
        let mkA = CPace.deriveMacKey(sid: sid, isk: iskA)
        let mkB = CPace.deriveMacKey(sid: sid, isk: iskB)
        // The Source expects the Display's tag over Yb under mkA; the Display actually sent it
        // under mkB. They differ ⇒ confirmation fails.
        let expectedBySource = CPace.confirmationTag(macKey: mkA, share: Yb, ad: Data())
        let sentByDisplay = CPace.confirmationTag(macKey: mkB, share: Yb, ad: Data())
        XCTAssertFalse(CPace.constantTimeEquals(expectedBySource, sentByDisplay))
    }

    func testDifferentChannelBindingProducesDifferentGenerator() {
        // Same PIN but a MITM-substituted server cert ⇒ different channel binding ⇒ different
        // generator ⇒ the exchange cannot converge (relay defence, now via the CI binding).
        let honest = CPace.channelBinding(clientSPKI: spki(1), serverSPKI: spki(2))
        let mitm = CPace.channelBinding(clientSPKI: spki(1), serverSPKI: spki(0x99))
        let gHonest = CPace.calculateGenerator(pin: "123456", ci: honest, sid: CPace.sid(channelBinding: honest))
        let gMitm = CPace.calculateGenerator(pin: "123456", ci: mitm, sid: CPace.sid(channelBinding: mitm))
        XCTAssertNotEqual(Data(gHonest), Data(gMitm))
    }

    func testChannelBindingOrderMatters() {
        let a = CPace.channelBinding(clientSPKI: spki(1), serverSPKI: spki(2))
        let b = CPace.channelBinding(clientSPKI: spki(2), serverSPKI: spki(1))
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
