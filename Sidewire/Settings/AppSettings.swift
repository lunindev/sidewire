import Foundation
import SwiftUI
import AppKit
import ServiceManagement

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

    /// Virtual-display scale. Auto follows the Display's negotiated scaleFactor; the others
    /// force it (e.g. a 1× desktop on a Retina Display, or vice-versa).
    enum VirtualDisplayScale: String, CaseIterable, Identifiable {
        case auto, hiDPI, standard
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: return "Auto (match Display)"
            case .hiDPI: return "HiDPI (2×)"
            case .standard: return "Standard (1×)"
            }
        }
        /// nil = auto (use the Display's scaleFactor); true/false force HiDPI/standard.
        var forcedHiDPI: Bool? {
            switch self {
            case .auto: return nil
            case .hiDPI: return true
            case .standard: return false
            }
        }
    }

    /// fps cap. 0 = no cap (use the negotiated maximum).
    static let fpsOptions = [0, 30, 60, 120]
    /// Bitrate ceiling options (Mbps).
    static let bitrateOptions = [20, 30, 50, 80, 100]

    @Published var codec: CodecPref { didSet { d.set(codec.rawValue, forKey: Keys.codec) } }
    @Published var maxFps: Int { didSet { d.set(maxFps, forKey: Keys.maxFps) } }
    @Published var maxBitrateMbps: Int { didSet { d.set(maxBitrateMbps, forKey: Keys.maxBitrate) } }
    @Published var resolutionPreset: ResolutionPreset { didSet { d.set(resolutionPreset.rawValue, forKey: Keys.resolution) } }
    @Published var virtualDisplayScale: VirtualDisplayScale { didSet { d.set(virtualDisplayScale.rawValue, forKey: Keys.virtualDisplayScale) } }
    @Published var autoConnectLastPeer: Bool { didSet { d.set(autoConnectLastPeer, forKey: Keys.autoConnect) } }
    /// Run without a Dock icon, living in the menu bar. Applied live via the activation policy.
    @Published var menuBarOnly: Bool {
        didSet { d.set(menuBarOnly, forKey: Keys.menuBarOnly); applyActivationPolicy() }
    }
    /// One-shot: the first-run welcome has been dismissed.
    @Published var hasSeenWelcome: Bool { didSet { d.set(hasSeenWelcome, forKey: Keys.hasSeenWelcome) } }

    /// D1 — start Sidewire at login. Backed by SMAppService (not UserDefaults): the login-item
    /// registration is the source of truth, so we mirror the OS state and register/unregister on
    /// change. Reflected from the actual status on load (the user can toggle it in System Settings).
    @Published var launchAtLogin: Bool {
        didSet {
            guard !suppressLaunchAtLoginApply else { return }
            applyLaunchAtLogin(launchAtLogin, previous: oldValue)
        }
    }
    /// Re-entrancy guard so a failed apply can revert the toggle without re-triggering apply.
    private var suppressLaunchAtLoginApply = false

    /// D2 — hold a power assertion (no display sleep) on the Display while a session is connected,
    /// so the spare Mac's screen doesn't sleep mid-stream. Default ON.
    @Published var keepAwakeWhileConnected: Bool {
        didSet { d.set(keepAwakeWhileConnected, forKey: Keys.keepAwake) }
    }

    /// D4 — override for the name shown to the other Mac / advertised over Bonjour. Empty = use
    /// `Host.current().localizedName` (see DeviceIdentity). Persisted; DeviceIdentity reads the
    /// same UserDefaults key so it needn't reach the main actor.
    @Published var deviceName: String {
        didSet { d.set(deviceName, forKey: Keys.deviceName) }
    }

    /// D6 — buffer .debug-level lines into the diagnostics ring buffer. Mirrored into LogBuffer,
    /// which owns the thread-safe flag + its own UserDefaults persistence.
    @Published var verboseLogging: Bool {
        didSet { LogBuffer.shared.setVerbose(verboseLogging) }
    }

    private let d = UserDefaults.standard
    private enum Keys {
        static let codec = "sidewire.codec"
        static let maxFps = "sidewire.maxFps"
        static let maxBitrate = "sidewire.maxBitrateMbps"
        static let resolution = "sidewire.resolution"
        static let virtualDisplayScale = "sidewire.virtualDisplayScale"
        static let autoConnect = "sidewire.autoConnect"
        static let menuBarOnly = "sidewire.menuBarOnly"
        static let hasSeenWelcome = "sidewire.hasSeenWelcome"
        static let keepAwake = "sidewire.keepAwakeWhileConnected"
        static let deviceName = "sidewire.deviceName"
    }
    /// The UserDefaults key DeviceIdentity reads for the D4 name override (kept in sync with
    /// `Keys.deviceName`; duplicated as a literal there because that enum is private).
    /// `nonisolated` so the nonisolated DeviceIdentity can reference it.
    nonisolated static let deviceNameDefaultsKey = "sidewire.deviceName"

    private init() {
        codec = CodecPref(rawValue: d.string(forKey: Keys.codec) ?? "") ?? .auto
        maxFps = (d.object(forKey: Keys.maxFps) as? Int) ?? 0
        maxBitrateMbps = (d.object(forKey: Keys.maxBitrate) as? Int) ?? 50
        resolutionPreset = ResolutionPreset(rawValue: d.string(forKey: Keys.resolution) ?? "") ?? .matchDisplay
        virtualDisplayScale = VirtualDisplayScale(rawValue: d.string(forKey: Keys.virtualDisplayScale) ?? "") ?? .auto
        autoConnectLastPeer = d.bool(forKey: Keys.autoConnect)
        menuBarOnly = d.bool(forKey: Keys.menuBarOnly)
        hasSeenWelcome = d.bool(forKey: Keys.hasSeenWelcome)
        // Default ON — absent key reads as false, so seed it on first run.
        keepAwakeWhileConnected = (d.object(forKey: Keys.keepAwake) as? Bool) ?? true
        deviceName = d.string(forKey: Keys.deviceName) ?? ""
        verboseLogging = LogBuffer.shared.verbose
        // Reflect the real login-item status (property observers don't fire during init).
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Register/unregister the app as a login item to match the toggle. On failure, log and
    /// revert the toggle (without re-entering apply). No-op when already in the desired state.
    private func applyLaunchAtLogin(_ enabled: Bool, previous: Bool) {
        do {
            if enabled {
                guard SMAppService.mainApp.status != .enabled else { return }
                try SMAppService.mainApp.register()
                Log.event(.app, "registered as a login item")
            } else {
                guard SMAppService.mainApp.status == .enabled else { return }
                try SMAppService.mainApp.unregister()
                Log.event(.app, "unregistered as a login item")
            }
        } catch {
            Log.event(.app, "launch-at-login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)", level: .error)
            suppressLaunchAtLoginApply = true
            launchAtLogin = previous
            suppressLaunchAtLoginApply = false
        }
    }

    var maxBitrateBps: Int { maxBitrateMbps * 1_000_000 }

    /// Reflect menuBarOnly into the app's Dock presence. `.accessory` hides the Dock icon;
    /// `.regular` restores it. Safe to call repeatedly.
    func applyActivationPolicy() {
        NSApp.setActivationPolicy(menuBarOnly ? .accessory : .regular)
    }
}

/// The quality-affecting settings snapshotted by an active Source link (D3). Compared against
/// the live AppSettings to decide whether "Changes apply on reconnect" should show — these are
/// exactly the values baked into a Session at connect time.
struct QualitySnapshot: Equatable {
    var codec: AppSettings.CodecPref
    var resolution: ResolutionPreset
    var maxFps: Int
    var maxBitrateMbps: Int
    var scale: AppSettings.VirtualDisplayScale

    @MainActor init(_ s: AppSettings) {
        codec = s.codec
        resolution = s.resolutionPreset
        maxFps = s.maxFps
        maxBitrateMbps = s.maxBitrateMbps
        scale = s.virtualDisplayScale
    }
}
