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

    static var deviceName: String {
        Host.current().localizedName ?? "Mac"
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
