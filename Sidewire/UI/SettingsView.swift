import SwiftUI

/// The ⌘, preferences pane: stream quality + connection preferences. All values persist
/// and take effect on the next connection.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Video") {
                // Codec is HEVC end-to-end today (the decoder is HEVC-only). Shown for
                // transparency rather than as a choice that couldn't take effect.
                LabeledContent("Codec", value: "HEVC (H.265)")
                Picker("Resolution", selection: $settings.resolutionPreset) {
                    ForEach(ResolutionPreset.allCases) { Text($0.label).tag($0) }
                }
                Picker("Max frame rate", selection: $settings.maxFps) {
                    ForEach(AppSettings.fpsOptions, id: \.self) { fps in
                        Text(fps == 0 ? "Unlimited" : "\(fps) fps").tag(fps)
                    }
                }
                Picker("Max bitrate", selection: $settings.maxBitrateMbps) {
                    ForEach(AppSettings.bitrateOptions, id: \.self) { mbps in
                        Text("\(mbps) Mbps").tag(mbps)
                    }
                }
            }

            Section("Connection") {
                Toggle("Auto-connect to the last Mac on launch", isOn: $settings.autoConnectLastPeer)
                Text("Reconnects to the last IP you connected to, using the saved PIN.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Show only in the menu bar (no Dock icon)", isOn: $settings.menuBarOnly)
                Text("Sidewire keeps running in the menu bar; reopen the window from there.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text("Changes apply to the next connection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 400)
    }
}
