import SwiftUI
import SidewireCore

/// Source role main window: discover Displays, connect, and see streaming status.
struct SourceView: View {
    @ObservedObject var controller: SourceController
    @EnvironmentObject var model: AppModel
    @StateObject private var permissions = PermissionsModel()
    @State private var manualHost = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            PermissionsView(model: permissions)

            GroupBox("Pairing PIN (shown on the Display)") {
                HStack {
                    TextField("6-digit PIN", text: $controller.pairingPIN)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .disabled(controller.isConnected || controller.isConnecting)
                    if controller.pairingPIN.count == 6 {
                        Label("Encrypted (TLS)", systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(.green)
                    } else {
                        Text("Enter the PIN shown on the other Mac.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
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
                    Label("Searching…", systemImage: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 0) {
                        ForEach(controller.peers) { peer in
                            HStack {
                                Image(systemName: "display")
                                Text(peer.name)
                                Spacer()
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

            GroupBox("Resolution") {
                HStack {
                    Picker("Resolution", selection: $controller.resolutionPreset) {
                        ForEach(ResolutionPreset.allCases) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    .disabled(controller.isConnected || controller.isConnecting)
                    Spacer()
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
            Button("Switch role") { model.switchRole() }
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

