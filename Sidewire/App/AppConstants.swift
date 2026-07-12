import Foundation
import AppKit
import SidewireProtocol

/// Stable per-install identity + local capability advertisement.
enum DeviceIdentity {
    private static let idKey = "sidewire.deviceId"

    /// A stable UUID for this install (Phase 3 pairing keys on this).
    static var deviceId: String {
        if let existing = UserDefaults.standard.string(forKey: idKey) { return existing }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: idKey)
        return new
    }

    /// The name shown to the other Mac (in HELLO) and advertised over Bonjour. A non-empty
    /// override from Settings (D4) wins — trimmed and capped at 40 chars — otherwise the
    /// system name. Read straight from UserDefaults (the same key AppSettings persists to) so
    /// this stays nonisolated; callers are on the main actor.
    static var deviceName: String {
        let override = (UserDefaults.standard.string(forKey: AppSettings.deviceNameDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty { return String(override.prefix(40)) }
        return Host.current().localizedName ?? "Mac"
    }

    /// Local capabilities. `videoCodecs` is probed from VideoToolbox (HEVC first when this
    /// machine can encode it, then H.264) rather than hardcoded — an Intel Mac with no HEVC
    /// hardware encoder advertises only h264, so negotiation never picks a codec it can't
    /// produce. Preference order (HEVC-then-H264) is preserved when both are available.
    static func capabilities() -> Capabilities {
        let screen = NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2.0
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 2560, height: 1600)
        return Capabilities(
            videoCodecs: VideoEncoder.supportedCodecs.map(\.rawValue),
            maxWidth: Int(frame.width * scale),
            maxHeight: Int(frame.height * scale),
            maxFps: 60,
            ltr: false,
            audio: false,
            hdr: false)
    }

    static func makeHello(role: Role, sessionId: String) -> Hello {
        Hello(role: role, deviceId: deviceId, deviceName: deviceName,
              sessionId: sessionId, capabilities: capabilities())
    }
}
