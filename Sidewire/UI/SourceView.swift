import SwiftUI
import SidewireCore

/// Source role main window: discover Displays, connect, and see streaming status.
struct SourceView: View {
    @ObservedObject var controller: SourceController
    @EnvironmentObject var model: AppModel
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var permissions = PermissionsModel()
    @State private var manualHost = SourceController.lastHost

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            PermissionsView(model: permissions)

            if controller.accessibilityRevoked {
                accessibilityBanner
            }

            GroupBox("Pairing PIN (shown on the Display)") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("6-digit PIN", text: $controller.pairingPIN)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                            .disabled(controller.isConnected || controller.isConnecting)
                            .onChange(of: controller.pairingPIN) { _, newValue in
                                // Digits only, capped at 6 — the PIN is a 6-digit code.
                                let filtered = String(newValue.filter(\.isNumber).prefix(6))
                                if filtered != newValue { controller.pairingPIN = filtered }
                            }
                        if controller.pairingPIN.count == 6 {
                            Label("Encrypted (TLS)", systemImage: "lock.fill")
                                .font(.caption).foregroundStyle(.green)
                        } else {
                            Text("Enter the PIN shown on the other Mac.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    if controller.pinRejected {
                        Label("PIN incorrect — check the code shown on the other Mac.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.red)
                    } else if controller.isConnected {
                        // Once paired, the peer's key is stored — the PIN is only needed to pair
                        // a new Mac (or after "Forget" on either side).
                        Label("Paired — the PIN is only needed to pair a Mac again.",
                              systemImage: "checkmark.seal.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            GroupBox("Displays on your network") {
                HStack {
                    InterfacePicker(controller: controller, monitor: controller.interfaceMonitor)
                        .frame(maxWidth: 240)
                    Spacer()
                    Button {
                        controller.refreshDiscovery()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .padding(.bottom, 4)
                Divider()

                if controller.peers.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Searching…", systemImage: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if controller.discoveryLikelyBlocked {
                            // Discovery has been stuck with nothing found — almost always Local
                            // Network permission denied (Bonjour returns nothing when it's off).
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("No Displays found. Local Network permission may be off — turn it on for Sidewire on both Macs.")
                                        .font(.caption)
                                    if let url = Permissions.localNetworkSettingsURL {
                                        Link("Open Local Network settings", destination: url)
                                            .font(.caption)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                } else {
                    VStack(spacing: 0) {
                        ForEach(controller.peers) { peer in
                            HStack {
                                Image(systemName: "display")
                                Text(peer.name)
                                Spacer()
                                if let tb = peer.thunderboltIP,
                                   controller.localThunderboltIP != nil, // this Mac has a TB bridge to route to it
                                   !controller.isConnected {
                                    Button {
                                        controller.connect(host: tb)
                                    } label: {
                                        Label("Thunderbolt", systemImage: "cable.connector")
                                    }
                                    .tint(.green)
                                    .disabled(controller.isConnecting || controller.pairingPIN.count != 6)
                                    .help("Connect over the Thunderbolt cable (\(tb))")
                                }
                                Button(connectTitle) {
                                    if controller.isConnected { controller.disconnect() }
                                    else { controller.connect(to: peer) }
                                }
                                .disabled(controller.isConnecting || (!controller.isConnected && controller.pairingPIN.count != 6))
                            }
                            .padding(.vertical, 6)
                            Divider()
                        }
                    }
                }
            }

            troubleshooting

            GroupBox("Connect by IP — forces Thunderbolt") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("169.254.x.x", text: $manualHost)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                        Button("Connect") { controller.connect(host: manualHost) }
                            .disabled(manualHost.isEmpty || controller.isConnected || controller.isConnecting || controller.pairingPIN.count != 6)
                    }
                    if let tb = controller.localThunderboltIP {
                        Label("Thunderbolt cable detected (this Mac: \(tb)). Enter the OTHER Mac's 169.254.x.x to go over the cable.",
                              systemImage: "cable.connector")
                            .font(.caption2).foregroundStyle(.green)
                    } else {
                        Text("No Thunderbolt Bridge found — connect a cable and check System Settings → Network.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            GroupBox("Quality") {
                HStack {
                    Picker("Resolution", selection: $settings.resolutionPreset) {
                        ForEach(ResolutionPreset.allCases) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    .disabled(controller.isConnected || controller.isConnecting)
                    Spacer()
                    SettingsLink {
                        Label("More settings…", systemImage: "slider.horizontal.3")
                    }
                }
            }

            VirtualDisplayStatusView(vd: controller.virtualDisplay,
                                     capture: controller.capture,
                                     isStreaming: controller.isStreaming)

            Spacer()
        }
        .padding(24)
    }

    private var connectTitle: String {
        if controller.isConnected { return "Disconnect" }
        return controller.isConnecting ? "Connecting…" : "Connect"
    }

    private var header: some View {
        HStack {
            Circle()
                .fill(controller.isConnected ? .green : .secondary)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text("Source").font(.headline)
                Text(controller.statusText).font(.caption).foregroundStyle(.secondary)
                if controller.isConnected, !controller.connectionInterface.isEmpty {
                    Label {
                        Text("via \(controller.connectionInterface)" +
                             (controller.rttMs > 0 ? " · \(Int(controller.rttMs)) ms" : "") +
                             (controller.currentBitrateMbps > 0 ? " · \(String(format: "%.0f", controller.currentBitrateMbps)) Mbps" : ""))
                    } icon: {
                        Image(systemName: controller.connectionInterface.hasPrefix("Thunderbolt") ? "cable.connector" : "wifi")
                    }
                    .font(.caption2)
                    .foregroundStyle(controller.connectionInterface.hasPrefix("Thunderbolt") ? .green : .secondary)
                }
            }
            Spacer()
            if controller.isConnecting {
                Button("Cancel") { controller.disconnect() }
            }
            Button("Switch role") { model.switchRole() }
        }
    }

    private var accessibilityBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Accessibility permission revoked — remote input disabled. Re-grant in System Settings › Privacy & Security.")
                .font(.caption)
            Spacer()
            Button("Open Settings") { Permissions.openAccessibilitySettings() }
                .font(.caption)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Collapsed-by-default guide for the two failures users actually hit but that the app can't
    /// always detect: Local Network permission, the firewall, network/VPN isolation, and both
    /// Macs picking the same role (backlog C1).
    private var troubleshooting: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                TroubleRow(icon: "lock.shield") {
                    Text("**Local Network permission.** Both Macs must allow it (System Settings › Privacy & Security › Local Network). If the prompt was denied, discovery finds nothing.")
                    if let url = Permissions.localNetworkSettingsURL {
                        Link("Open Local Network settings", destination: url)
                    }
                }
                TroubleRow(icon: "flame") {
                    Text("**Firewall.** The macOS firewall on the Display Mac (System Settings › Network › Firewall) can block incoming connections — allow Sidewire. \u{201C}Connect by IP\u{201D} needs this too.")
                }
                TroubleRow(icon: "wifi") {
                    Text("**Same network.** Both Macs must be on the same Wi-Fi/LAN; a VPN can isolate them. A Thunderbolt cable is the reliable fallback.")
                }
                TroubleRow(icon: "arrow.2.squarepath") {
                    Text("**Roles.** The other Mac must be set to \u{201C}Use as a display\u{201D}. If both are sharing, this list stays empty.")
                }
            }
            .font(.caption)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Can't connect?", systemImage: "questionmark.circle")
                .font(.callout)
        }
    }
}

/// One troubleshooting row: a leading SF Symbol and secondary-styled explanatory content.
private struct TroubleRow<Content: View>: View {
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) { content }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct VirtualDisplayStatusView: View {
    @ObservedObject var vd: VirtualDisplayManager
    @ObservedObject var capture: ScreenCapture
    let isStreaming: Bool

    var body: some View {
        GroupBox("Virtual display") {
            HStack(spacing: 16) {
                Circle().fill(vd.isActive ? .green : .orange).frame(width: 8, height: 8)
                Text(vd.statusMessage).font(.caption)
                Spacer()
                if isStreaming {
                    Text("\(Int(capture.fps)) fps").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct InterfacePicker: View {
    @ObservedObject var controller: SourceController
    @ObservedObject var monitor: InterfaceMonitor

    var body: some View {
        Picker("Network", selection: $controller.selectedInterfaceName) {
            Text("Auto").tag("")
            ForEach(monitor.interfaces) { iface in
                Text(iface.label).tag(iface.name)
            }
        }
        .labelsHidden()
        .disabled(controller.isConnected || controller.isConnecting)
    }
}

