import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

/// Minimal permission helpers for Phase 0. The full onboarding checklist (relaunch
/// handling, Local Network, illustrated directions) is Phase 4 — see docs/06.
enum Permissions {
    /// Screen Recording is required on the Source to capture the virtual display.
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    /// Accessibility is required on the Source to inject keyboard/mouse via CGEvent.
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openScreenRecordingSettings() {
        openSettings("Privacy_ScreenCapture")
    }

    static func openAccessibilitySettings() {
        openSettings("Privacy_Accessibility")
    }

    private static func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
