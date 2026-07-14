import SwiftUI
import SidewireCore

/// The ⌘, preferences pane: stream quality + connection preferences. Most values persist and
/// take effect on the next connection; the "Reconnect to apply" row (D3) applies quality
/// changes to a live Source session on demand.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updater: UpdaterController

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

            PairedMacsSection()

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

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }))
                    .disabled(!updater.isConfigured)
                if updater.isConfigured {
                    Text("Checks GitHub for a newer signed version. This is Sidewire's only connection to the internet — there are no accounts and no telemetry. Updates are verified with an EdDSA signature.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Auto-update isn't set up in this build (no signing key / release feed yet), so update checks are turned off.")
                        .font(.caption).foregroundStyle(.secondary)
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

/// The Keychain trust store's paired Macs, with a per-row "Forget" (revokes trust; that Mac must
/// re-pair with the PIN on its next connection — docs/05). Refreshes when the store changes.
private struct PairedMacsSection: View {
    @State private var peers: [TrustedPeer] = []

    var body: some View {
        Section("Paired Macs") {
            if peers.isEmpty {
                Text("No paired Macs yet. Pair by entering the other Mac's PIN when you connect.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(peers, id: \.deviceId) { peer in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.name.isEmpty ? "Unnamed Mac" : peer.name)
                            Text("Paired \(Self.dateText(peer.pairedAt))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Forget") { forget(peer) }
                    }
                }
                Text("Forgetting a Mac means it must re-pair with the PIN next time it connects.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .sidewirePairedPeersChanged)) { _ in reload() }
    }

    private func reload() { peers = KeychainTrustStore.shared.peers() }

    private func forget(_ peer: TrustedPeer) {
        KeychainTrustStore.shared.forget(peer.deviceId)
        reload()
    }

    private static func dateText(_ epoch: Double) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: epoch))
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
