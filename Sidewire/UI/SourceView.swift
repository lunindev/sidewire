import SwiftUI
import SidewireCore

/// Source role main window: discover Displays, connect, and see streaming status.
struct SourceView: View {
    @ObservedObject var controller: SourceController
    @EnvironmentObject var model: AppModel
    @State private var manualHost = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

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
                                .disabled(controller.isConnecting)
                            }
                            .padding(.vertical, 6)
                            Divider()
                        }
                    }
                }
            }

            GroupBox("Connect by IP (Thunderbolt link-local)") {
                HStack {
                    TextField("169.254.x.x", text: $manualHost)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    Button("Connect") { controller.connect(host: manualHost) }
                        .disabled(manualHost.isEmpty || controller.isConnected || controller.isConnecting)
                }
            }

            VirtualDisplayStatusView(vd: controller.virtualDisplay,
                                     capture: controller.capture,
                                     isStreaming: controller.isStreaming)

            PermissionsRow()

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
                             (controller.rttMs > 0 ? " · \(Int(controller.rttMs)) ms RTT" : ""))
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

private struct PermissionsRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Button("Grant Screen Recording") {
                _ = Permissions.requestScreenRecording()   // prompts the first time / registers the app
                Permissions.openScreenRecordingSettings()  // and open the pane (reliable if the prompt won't show)
            }
            Button("Grant Input Control") {
                _ = Permissions.requestAccessibility()
                Permissions.openAccessibilitySettings()
            }
        }
        .font(.caption)
    }
}
