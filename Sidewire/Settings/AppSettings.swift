import Foundation
import SwiftUI
import AppKit

/// Virtual-display resolution options (pixel dimensions; the display is created HiDPI so
/// the logical size is half). "Match Display" uses the receiver's native panel.
enum ResolutionPreset: String, CaseIterable, Identifiable {
    case matchDisplay, r3456x2234, r2880x1800, r2560x1600, r1920x1200

    var id: String { rawValue }
    var label: String {
        switch self {
        case .matchDisplay: return "Match Display"
        case .r3456x2234: return "3456×2234 (16\" Retina)"
        case .r2880x1800: return "2880×1800"
        case .r2560x1600: return "2560×1600"
        case .r1920x1200: return "1920×1200"
        }
    }
    var dimensions: (width: Int, height: Int)? {
        switch self {
        case .matchDisplay: return nil
        case .r3456x2234: return (3456, 2234)
        case .r2880x1800: return (2880, 1800)
        case .r2560x1600: return (2560, 1600)
        case .r1920x1200: return (1920, 1200)
        }
    }
}

/// App-wide, persisted stream preferences. A shared singleton so the Source can read the
/// current values when it builds a session; the Settings pane binds to it directly.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum CodecPref: String, CaseIterable, Identifiable {
        case auto, hevc, h264
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: return "Auto (HEVC if available)"
            case .hevc: return "HEVC (H.265)"
            case .h264: return "H.264"
            }
        }
        /// nil = let negotiation pick; otherwise force this codec if both peers support it.
        var forced: String? { self == .auto ? nil : rawValue }
    }

    /// fps cap. 0 = no cap (use the negotiated maximum).
    static let fpsOptions = [0, 30, 60, 120]
    /// Bitrate ceiling options (Mbps).
    static let bitrateOptions = [20, 30, 50, 80, 100]

    @Published var codec: CodecPref { didSet { d.set(codec.rawValue, forKey: Keys.codec) } }
    @Published var maxFps: Int { didSet { d.set(maxFps, forKey: Keys.maxFps) } }
    @Published var maxBitrateMbps: Int { didSet { d.set(maxBitrateMbps, forKey: Keys.maxBitrate) } }
    @Published var resolutionPreset: ResolutionPreset { didSet { d.set(resolutionPreset.rawValue, forKey: Keys.resolution) } }
    @Published var autoConnectLastPeer: Bool { didSet { d.set(autoConnectLastPeer, forKey: Keys.autoConnect) } }
    /// Run without a Dock icon, living in the menu bar. Applied live via the activation policy.
    @Published var menuBarOnly: Bool {
        didSet { d.set(menuBarOnly, forKey: Keys.menuBarOnly); applyActivationPolicy() }
    }
    /// One-shot: the first-run welcome has been dismissed.
    @Published var hasSeenWelcome: Bool { didSet { d.set(hasSeenWelcome, forKey: Keys.hasSeenWelcome) } }

    private let d = UserDefaults.standard
    private enum Keys {
        static let codec = "sidewire.codec"
        static let maxFps = "sidewire.maxFps"
        static let maxBitrate = "sidewire.maxBitrateMbps"
        static let resolution = "sidewire.resolution"
        static let autoConnect = "sidewire.autoConnect"
        static let menuBarOnly = "sidewire.menuBarOnly"
        static let hasSeenWelcome = "sidewire.hasSeenWelcome"
    }

    private init() {
        codec = CodecPref(rawValue: d.string(forKey: Keys.codec) ?? "") ?? .auto
        maxFps = (d.object(forKey: Keys.maxFps) as? Int) ?? 0
        maxBitrateMbps = (d.object(forKey: Keys.maxBitrate) as? Int) ?? 50
        resolutionPreset = ResolutionPreset(rawValue: d.string(forKey: Keys.resolution) ?? "") ?? .matchDisplay
        autoConnectLastPeer = d.bool(forKey: Keys.autoConnect)
        menuBarOnly = d.bool(forKey: Keys.menuBarOnly)
        hasSeenWelcome = d.bool(forKey: Keys.hasSeenWelcome)
    }

    var maxBitrateBps: Int { maxBitrateMbps * 1_000_000 }

    /// Reflect menuBarOnly into the app's Dock presence. `.accessory` hides the Dock icon;
    /// `.regular` restores it. Safe to call repeatedly.
    func applyActivationPolicy() {
        NSApp.setActivationPolicy(menuBarOnly ? .accessory : .regular)
    }
}
