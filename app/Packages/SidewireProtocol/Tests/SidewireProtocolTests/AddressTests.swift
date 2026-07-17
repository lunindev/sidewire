import XCTest
@testable import SidewireProtocol

final class AddressTests: XCTestCase {

    func testBareAddressGetsTheDefaultPort() {
        let parsed = Address.parse("169.254.3.4")
        XCTAssertEqual(parsed?.host, "169.254.3.4")
        XCTAssertEqual(parsed?.port, ProtocolConstants.fallbackPort)
    }

    func testExplicitPort() {
        let parsed = Address.parse("169.254.3.4:5006")
        XCTAssertEqual(parsed?.host, "169.254.3.4")
        XCTAssertEqual(parsed?.port, 5006)
    }

    /// The regression this type exists for: spaces around the colon used to defeat the port parse,
    /// and the whole string — colon and spaces included — was then dialled as a hostname and
    /// retried forever.
    func testSpacesAroundTheColonAreTrimmedPerPart() {
        let parsed = Address.parse("169.254.3.4 : 5006")
        XCTAssertEqual(parsed?.host, "169.254.3.4")
        XCTAssertEqual(parsed?.port, 5006)
    }

    func testSurroundingWhitespaceIsIgnored() {
        let parsed = Address.parse("   169.254.3.4   ")
        XCTAssertEqual(parsed?.host, "169.254.3.4")
        XCTAssertEqual(parsed?.port, ProtocolConstants.fallbackPort)
    }

    func testHostnameIsAccepted() {
        XCTAssertEqual(Address.parse("mac-mini.local")?.host, "mac-mini.local")
    }

    /// Several colons means an IPv6 literal; pass it through untouched at the default port.
    func testIPv6LiteralPassesThroughAtDefaultPort() {
        let parsed = Address.parse("fe80::1")
        XCTAssertEqual(parsed?.host, "fe80::1")
        XCTAssertEqual(parsed?.port, ProtocolConstants.fallbackPort)
    }

    func testRejectsEmptyAndWhitespaceOnly() {
        XCTAssertNil(Address.parse(""))
        XCTAssertNil(Address.parse("     "))
    }

    func testRejectsMissingOrJunkPort() {
        XCTAssertNil(Address.parse("169.254.3.4:"))
        XCTAssertNil(Address.parse("169.254.3.4:abc"))
        XCTAssertNil(Address.parse("169.254.3.4:50 06"))
    }

    /// Port 0 is not dialable, and 65536 overflows UInt16 — both must fail the parse rather than
    /// wrap or clamp into something that looks plausible.
    func testRejectsOutOfRangePorts() {
        XCTAssertNil(Address.parse("169.254.3.4:0"))
        XCTAssertNil(Address.parse("169.254.3.4:65536"))
        XCTAssertNil(Address.parse("169.254.3.4:-1"))
    }

    func testRejectsMissingHost() {
        XCTAssertNil(Address.parse(":5006"))
        XCTAssertNil(Address.parse(" : 5006"))
    }

    func testRejectsSpacesInsideTheHost() {
        XCTAssertNil(Address.parse("my mac"))
        XCTAssertNil(Address.parse("my mac:5006"))
    }

    /// CharacterSet.whitespaces is spaces and tabs only — a pasted value carrying a newline used
    /// to survive trimming and get dialled with the newline still attached.
    func testNewlinesAndTabsAreTrimmed() {
        XCTAssertEqual(Address.parse("169.254.3.4\n")?.host, "169.254.3.4")
        XCTAssertEqual(Address.parse("\n169.254.3.4\n")?.host, "169.254.3.4")
        XCTAssertEqual(Address.parse("\t169.254.3.4\t")?.host, "169.254.3.4")
        XCTAssertEqual(Address.parse("169.254.3.4\r\n:5006")?.port, 5006)
        XCTAssertEqual(Address.parse("169.254.3.4:\n5006")?.port, 5006)
    }

    func testRejectsWhitespaceInsideTheValue() {
        XCTAssertNil(Address.parse("169.254\n.3.4"))
        XCTAssertNil(Address.parse("169.254.3.4:50\n06"))
    }

    /// Brackets are syntax, not address. Passing them through handed the whole string — port and
    /// all — to the resolver as a DNS name.
    func testBracketedIPv6() {
        XCTAssertEqual(Address.parse("[fe80::1]")?.host, "fe80::1")
        XCTAssertEqual(Address.parse("[fe80::1]")?.port, ProtocolConstants.fallbackPort)

        let withPort = Address.parse("[fe80::1]:5006")
        XCTAssertEqual(withPort?.host, "fe80::1")
        XCTAssertEqual(withPort?.port, 5006)

        XCTAssertEqual(Address.parse("[2001:db8::8a2e:370:7334]:443")?.host, "2001:db8::8a2e:370:7334")
    }

    func testRejectsMalformedBrackets() {
        XCTAssertNil(Address.parse("[fe80::1"))
        XCTAssertNil(Address.parse("[]"))
        XCTAssertNil(Address.parse("[]:5006"))
        XCTAssertNil(Address.parse("[fe80::1]5006"))   // missing the ":" before the port
        XCTAssertNil(Address.parse("[fe80::1]:"))
        XCTAssertNil(Address.parse("[fe80::1]:abc"))
        XCTAssertNil(Address.parse("[fe80::1]:0"))
    }

    func testDefaultPortIsOverridable() {
        XCTAssertEqual(Address.parse("169.254.3.4", defaultPort: 9000)?.port, 9000)
        // An explicit port always wins over the default.
        XCTAssertEqual(Address.parse("169.254.3.4:5006", defaultPort: 9000)?.port, 5006)
    }
}
