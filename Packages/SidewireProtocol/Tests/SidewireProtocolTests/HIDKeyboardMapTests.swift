import XCTest
@testable import SidewireProtocol

/// Verifies the macOS-virtual-keycode ⇄ HID-usage table is a bijection and that a mac keycode
/// survives a mac→HID→mac round-trip (the identity the app's capture→inject path relies on).
final class HIDKeyboardMapTests: XCTestCase {

    func testForwardMapIsInjective() {
        // No two distinct mac keycodes may map to the same HID usage, or the reverse map (and the
        // injector) would be ambiguous.
        let forward = HIDKeyboardMap.macVirtualToHID
        XCTAssertEqual(Set(forward.values).count, forward.count, "HID usages must be unique per mac keycode")
        // And the derived reverse table must have exactly one entry per forward entry.
        XCTAssertEqual(HIDKeyboardMap.hidToMacVirtual.count, forward.count)
    }

    func testMacToHIDToMacIdentityForWholeMappedSet() {
        for (mac, hid) in HIDKeyboardMap.macVirtualToHID {
            XCTAssertEqual(HIDKeyboardMap.hidUsage(fromMacVirtualKey: mac), hid)
            XCTAssertEqual(HIDKeyboardMap.macVirtualKey(fromHIDUsage: hid), mac,
                           "mac 0x\(String(mac, radix: 16)) → HID 0x\(String(hid, radix: 16)) → mac must be identity")
        }
    }

    func testHIDToMacToHIDIdentityForWholeMappedSet() {
        for (hid, mac) in HIDKeyboardMap.hidToMacVirtual {
            XCTAssertEqual(HIDKeyboardMap.macVirtualKey(fromHIDUsage: hid), mac)
            XCTAssertEqual(HIDKeyboardMap.hidUsage(fromMacVirtualKey: mac), hid)
        }
    }

    func testSpotChecksAgainstKnownUsages() {
        // A few anchors from the USB HID keyboard usage table.
        XCTAssertEqual(HIDKeyboardMap.hidUsage(fromMacVirtualKey: 0x00), 0x04) // A
        XCTAssertEqual(HIDKeyboardMap.hidUsage(fromMacVirtualKey: 0x24), 0x28) // Return
        XCTAssertEqual(HIDKeyboardMap.hidUsage(fromMacVirtualKey: 0x31), 0x2C) // Space
        XCTAssertEqual(HIDKeyboardMap.hidUsage(fromMacVirtualKey: 0x7E), 0x52) // Up Arrow
        XCTAssertEqual(HIDKeyboardMap.hidUsage(fromMacVirtualKey: 0x38), 0xE1) // Left Shift
        XCTAssertEqual(HIDKeyboardMap.hidUsage(fromMacVirtualKey: 0x37), 0xE3) // Left Command → GUI
        XCTAssertEqual(HIDKeyboardMap.macVirtualKey(fromHIDUsage: 0x29), 0x35) // Escape
    }

    func testUnmappedCodesReturnNil() {
        // 0xFFFF is not a real macOS keycode / HID usage.
        XCTAssertNil(HIDKeyboardMap.hidUsage(fromMacVirtualKey: 0xFFFF))
        XCTAssertNil(HIDKeyboardMap.macVirtualKey(fromHIDUsage: 0xFFFF))
        // HID usage 0 = "no key" is not in the table.
        XCTAssertNil(HIDKeyboardMap.macVirtualKey(fromHIDUsage: 0x00))
    }
}
