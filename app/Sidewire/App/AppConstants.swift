import Foundation
import AppKit
import SidewireProtocol
import SidewireCore

/// Stable per-install identity + local capability advertisement.
enum DeviceIdentity {
    /// This install's self-authenticating device id, derived from its P-256 TLS identity
    /// (`first16(SPKI-SHA256)` hex — see `SidewireCore.LocalIdentity`). It is bound to the
    /// device's public key, so a peer cannot claim this id without holding the matching private
    /// key; that binding is what lets the trust store pin by id. Advertised in HELLO and in the
    /// Bonjour "did" TXT record.
    /// `nil` when the Keychain would not yield an identity — see `LocalIdentity.shared`. Callers
    /// cannot connect in that state anyway, so they surface the error rather than substituting a
    /// placeholder id that would advertise a device nobody can authenticate.
    static var deviceId: String? { LocalIdentity.shared?.deviceId }

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

    /// Build this Mac's HELLO. `deviceId` is passed in rather than read from `LocalIdentity` here,
    /// so the caller — which already had to obtain an identity to open a transport at all — proves
    /// it has one instead of this silently substituting a placeholder.
    static func makeHello(role: Role, deviceId: String, sessionId: String) -> Hello {
        Hello(role: role, deviceId: deviceId, deviceName: deviceName,
              sessionId: sessionId, capabilities: capabilities())
    }
}
