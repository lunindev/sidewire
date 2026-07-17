import XCTest
import Crypto
@testable import SidewireCore
import SidewireProtocol

/// Reproduces the **published** test vectors of `draft-irtf-cfrg-cpace-21` for the
/// CPACE-X25519-SHA512-ELLIGATOR2 ciphersuite, byte-for-byte. This is how we trust the crypto:
/// if any intermediate (generator, share, K, ISK) diverges from the draft, these fail loudly.
///
/// Source: https://github.com/cfrg/draft-irtf-cfrg-cpace `testvectors.md`, section
/// "Test vector for CPace using group X25519 and hash SHA-512".
final class CPaceVectorTests: XCTestCase {

    private func hex(_ s: String) -> Data { Data(hexString: s) }
    private func hexA(_ s: String) -> [UInt8] { [UInt8](Data(hexString: s)) }

    // Draft inputs (B.1).
    private let prs = Data("Password".utf8)
    private let ci = Data(hexString: "6f630b425f726573706f6e6465720b415f696e69746961746f72")
    private let sid = Data(hexString: "7e4b4791d6a8ef019b936c79fb7f2c57")
    private let ada = Data("ADa".utf8)
    private let adb = Data("ADb".utf8)
    private let ya = [UInt8](Data(hexString: "21b4f4bd9e64ed355c3eb676a28ebedaf6d8f17bdc365995b319097153044080"))
    private let yb = [UInt8](Data(hexString: "848b0779ff415f0af4ea14df9dd1d3c29ac41d836c7808896c4eba19c51ac40a"))

    // MARK: - String utilities (draft §A.1)

    func testPrependLenAndLvCat() {
        XCTAssertEqual(CPace.prependLen(Data()).map { $0 }, [0x00])
        XCTAssertEqual(CPace.prependLen(Data("1234".utf8)), hex("0431323334"))
        // 127-byte input → single-byte 0x7f prefix; 128 → two-byte LEB128 0x8001.
        XCTAssertEqual(CPace.prependLen(Data((0..<127).map { UInt8($0) })).prefix(1), hex("7f"))
        XCTAssertEqual(CPace.prependLen(Data((0..<128).map { UInt8($0) })).prefix(2), hex("8001"))
        XCTAssertEqual(CPace.lvCat([Data("1234".utf8), Data("5".utf8), Data(), Data("678".utf8)]),
                       hex("043132333401350003363738"))
    }

    // MARK: - Generator (draft §B.1.1)

    func testGeneratorString() {
        let gen = CPace.generatorString(prs: prs, ci: ci, sid: sid)
        XCTAssertEqual(gen.count, 172)
        let expected = "0843506163653235350850617373776f72646d" + String(repeating: "00", count: 109) +
            "1a6f630b425f726573706f6e6465720b415f696e69746961746f72107e4b4791d6a8ef019b936c79fb7f2c57"
        XCTAssertEqual(gen, hex(expected))
    }

    func testCalculateGenerator() {
        // Full path: SHA-512(gen)[:32] → decodeUCoordinate → Elligator2.
        let gen = CPace.generatorString(prs: prs, ci: ci, sid: sid)
        let h32 = Array(SHA512.hash(data: gen).prefix(32))
        XCTAssertEqual(Data(h32), hex("92806dc608984dbf4e4aae478c6ec453ae979cc01ecc1a2a7cf49f5cee56551b"))
        var u = h32; u[31] &= 0x7F
        let g = Elligator2.map(fieldBytes: u)
        XCTAssertEqual(Data(g), hex("64e8099e3ea682cfdc5cb665c057ebb514d06bf23ebc9f743b51b82242327074"))
    }

    // MARK: - Shares, K, ISK (draft §B.1.2–B.1.5)

    func testSharesAndKAndISK() {
        let g = hexA("64e8099e3ea682cfdc5cb665c057ebb514d06bf23ebc9f743b51b82242327074")
        let Ya = CPace.scalarMult(scalar: ya, u: g)!
        let Yb = CPace.scalarMult(scalar: yb, u: g)!
        XCTAssertEqual(Data(Ya), hex("1b02dad6dbd29a07b6d28c9e04cb2f184f0734350e32bb7e62ff9dbcfdb63d15"))
        XCTAssertEqual(Data(Yb), hex("20cda5955f82c4931545bcbf40758ce1010d7db4db2a907013d79c7a8fcf957f"))

        let Ka = CPace.scalarMultVfy(scalar: ya, peerShare: Yb)!
        let Kb = CPace.scalarMultVfy(scalar: yb, peerShare: Ya)!
        XCTAssertEqual(Ka, Kb)
        XCTAssertEqual(Data(Ka), hex("f97fdfcfff1c983ed6283856a401de3191ca919902b323c5f950c9703df7297a"))

        // ISK, initiator-responder ordering (transcript_ir).
        let isk = CPace.deriveISK(sid: sid, k: Ka,
                                  initiatorShare: Ya, initiatorAD: ada,
                                  responderShare: Yb, responderAD: adb)
        XCTAssertEqual(isk, hex("""
        a051ee5ee2499d16da3f69f430218b8ea94a18a45b67f9e86495b382c33d14a5\
        c38cecc0cc834f960e39e0d1bf7d76b9ef5d54eecc5e0f386c97ad12da8c3d5f
        """))
    }

    // MARK: - Elligator2 map vector (draft §B.1.1 intermediate)

    /// A standalone Elligator2 map vector: the draft's decoded field element maps to its generator.
    func testElligator2MapVector() {
        let u = hexA("92806dc608984dbf4e4aae478c6ec453ae979cc01ecc1a2a7cf49f5cee56551b")
        // bit #255 already clear (last byte 0x1b), so decodeUCoordinate is a no-op here.
        XCTAssertEqual(Data(Elligator2.map(fieldBytes: u)),
                       hex("64e8099e3ea682cfdc5cb665c057ebb514d06bf23ebc9f743b51b82242327074"))
    }

    // MARK: - scalar_mult_vfy low-order points (draft §B.1.10)

    /// The low-order u-coordinates that MUST abort (K = I) when received as a peer share.
    func testScalarMultVfyRejectsLowOrderPoints() {
        let s = hexA("af46e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449aff")
        let abortInputs = [
            "0000000000000000000000000000000000000000000000000000000000000000",
            "0100000000000000000000000000000000000000000000000000000000000000",
            "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
            "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
            "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157",
            "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
            "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        ]
        for u in abortInputs {
            XCTAssertNil(CPace.scalarMultVfy(scalar: s, peerShare: hexA(u)),
                         "low-order point \(u) must abort (K = I)")
        }
        // A high-order point (bit #255 set, cleared per RFC 7748) must NOT abort.
        let highOrder = "daffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        XCTAssertEqual(CPace.scalarMultVfy(scalar: s, peerShare: hexA(highOrder)).map { Data($0) },
                       hex("d8e2c776bbacd510d09fd9278b7edcd25fc5ae9adfba3b6e040e8d3b71b21806"))
    }

    // MARK: - Field arithmetic self-consistency

    /// An independent check of Field25519 mul/inv against a Python-computed reference
    /// (0x00..1f · 0x20..3f mod p, and (0x00..1f)⁻¹).
    func testFieldArithmeticReference() {
        let a = (0..<32).map { UInt8($0) }
        let b = (32..<64).map { UInt8($0) }
        let fa = Field25519(littleEndian: a)
        let fb = Field25519(littleEndian: b)
        XCTAssertEqual(Data((fa * fb).littleEndianBytes()),
                       hex("1f8a85cd3caefc029ca2f163d41d1ba79cd62f83ab83e6aeb7dbf5e077951450"))
        XCTAssertEqual(Data(fa.inverted().littleEndianBytes()),
                       hex("4dcd88822d0589ded58c28d85290e85dcd88822d0589ded58c28d85290e85d73"))
        // a · a⁻¹ == 1
        XCTAssertEqual(fa * fa.inverted(), Field25519.one)
    }
}

extension Data {
    /// Decode a hex string (ignoring internal whitespace/newlines) to bytes — test helper.
    init(hexString: String) {
        let chars = hexString.filter { !$0.isWhitespace }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var idx = chars.startIndex
        while idx < chars.endIndex {
            let next = chars.index(idx, offsetBy: 2)
            bytes.append(UInt8(chars[idx..<next], radix: 16)!)
            idx = next
        }
        self.init(bytes)
    }
}
