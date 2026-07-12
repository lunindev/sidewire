import SwiftUI

/// The ⌘, preferences pane: stream quality + connection preferences. Most values persist and
/// take effect on the next connection; the "Reconnect to apply" row (D3) applies quality
/// changes to a live Source session on demand.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Video") {
                Picker("Codec", selection: $settings.codec) {
                    ForEach(AppSettings.CodecPref.allCases) { Text($0.label).tag($0) }
                }
                Picker("Resolution", selection: $settings.resolutionPreset) {
                    ForEach(ResolutionPreset.allCases) { Text($0.label).tag($0) }
                }
                Picker("Virtual display scale", selection: $settings.virtualDisplayScale) {
                    ForEach(AppSettings.VirtualDisplayScale.allCases) { Text($0.label).tag($0) }
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

            // D3 — while a Source session is live and its baked-in quality differs from the
            // current settings, offer a one-click reconnect that re-dials with the new values.
            if let source = model.source {
                ReconnectHintSection(source: source)
            }

            Section("Connection") {
                Toggle("Auto-connect to the last Mac on launch", isOn: $settings.autoConnectLastPeer)
                Text("Reconnects to the last IP you connected to, using the saved PIN.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch Sidewire at login", isOn: $settings.launchAtLogin)

                Toggle("Keep this Mac awake while connected", isOn: $settings.keepAwakeWhileConnected)
                Text("Stops this Mac's screen from sleeping while it's acting as a display for another Mac.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Show only in the menu bar (no Dock icon)", isOn: $settings.menuBarOnly)
                Text("Sidewire keeps running in the menu bar; reopen the window from there.")
                    .font(.caption).foregroundStyle(.secondary)

                LabeledContent("Device name") {
                    TextField("This Mac's name", text: $settings.deviceName)
                        .frame(width: 200)
                        .onChange(of: settings.deviceName) { _, newValue in
                            // Cap at 40 (DeviceIdentity trims/caps the same way on read).
                            if newValue.count > 40 { settings.deviceName = String(newValue.prefix(40)) }
                        }
                }
                Text("Shown to the other Mac. Leave blank to use this Mac's name. Applies to new connections; the Display re-advertises its Bonjour name after you relaunch or switch roles.")
                    .font(.caption).foregroundStyle(.secondary)

                Button("Show Welcome…") {
                    NotificationCenter.default.post(name: .sidewireShowWelcome, object: nil)
                }
            }

            Section("Diagnostics") {
                Toggle("Verbose logging", isOn: $settings.verboseLogging)
                Text("Includes debug-level detail in the log buffer and exported diagnostics.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Export Diagnostics…") {
                    DiagnosticsExport.presentSavePanel()
                }
                Text("Saves a text file with app/OS info, your settings, and recent logs — useful for reporting a problem.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text("Most changes apply to the next connection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
    }
}

/// D3 — "Changes apply on reconnect". Observes the active Source so it appears/disappears as the
/// connection state and the live quality settings change.
private struct ReconnectHintSection: View {
    @ObservedObject var source: SourceController
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        if source.isConnected, let active = source.activeQuality, active != QualitySnapshot(settings) {
            Section {
                HStack {
                    Label("Changes apply on reconnect", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reconnect") { source.reconnectWithCurrentSettings() }
                }
            }
        }
    }
}
