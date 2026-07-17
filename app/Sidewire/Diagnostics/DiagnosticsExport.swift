import Foundation
import AppKit
import UniformTypeIdentifiers

/// Builds and saves a plain-text diagnostics report (D6): environment + settings snapshot +
/// the in-memory log ring buffer. Triggered by "Export Diagnostics…" in Settings.
@MainActor
enum DiagnosticsExport {
    /// Assemble the full report text.
    static func report() -> String {
        var out = ""
        func line(_ s: String = "") { out += s + "\n" }

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osStr = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"

        line("Sidewire Diagnostics")
        line("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        line("App version: \(version) (build \(build))")
        line("macOS: \(osStr)")
        line("Hardware model: \(hardwareModel())")
        line("Role: \(currentRole())")
        line()
        line("== Settings ==")
        for (k, v) in settingsSnapshot() { line("\(k): \(v)") }
        line()

        let lines = Log.buffer.snapshot()
        line("== Log (\(lines.count) lines, verbose=\(Log.buffer.verbose)) ==")
        if lines.isEmpty {
            line("(empty — nothing logged this session yet)")
        } else {
            for l in lines { line(l) }
        }
        return out
    }

    /// Present a save panel and write the report. Returns silently on cancel / error (logged).
    static func presentSavePanel() {
        let panel = NSSavePanel()
        panel.title = "Export Sidewire Diagnostics"
        panel.nameFieldStringValue = defaultFilename()
        panel.allowedContentTypes = [.plainText]
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report().write(to: url, atomically: true, encoding: .utf8)
            Log.event(.app, "diagnostics exported")
        } catch {
            Log.event(.app, "diagnostics export failed: \(error.localizedDescription)", level: .error)
        }
    }

    private static func defaultFilename() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "Sidewire-Diagnostics-\(f.string(from: Date())).txt"
    }

    /// Role read straight from UserDefaults (AppModel isn't in Settings' environment).
    private static func currentRole() -> String {
        UserDefaults.standard.string(forKey: "sidewire.role") ?? "not chosen"
    }

    private static func settingsSnapshot() -> [(String, String)] {
        let s = AppSettings.shared
        return [
            ("codec", s.codec.rawValue),
            ("resolution", s.resolutionPreset.rawValue),
            ("virtualDisplayScale", s.virtualDisplayScale.rawValue),
            ("maxFps", s.maxFps == 0 ? "unlimited" : "\(s.maxFps)"),
            ("maxBitrateMbps", "\(s.maxBitrateMbps)"),
            ("autoConnectLastPeer", "\(s.autoConnectLastPeer)"),
            ("menuBarOnly", "\(s.menuBarOnly)"),
            ("launchAtLogin", "\(s.launchAtLogin)"),
            ("keepAwakeWhileConnected", "\(s.keepAwakeWhileConnected)"),
            ("deviceName", s.deviceName.isEmpty ? "(system name)" : s.deviceName),
            ("verboseLogging", "\(s.verboseLogging)"),
        ]
    }

    /// `hw.model` identifier (e.g. "Mac15,3"). Best-effort; empty string on failure.
    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
