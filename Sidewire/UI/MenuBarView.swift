import SwiftUI

/// The menu-bar popover surface. Phase 0 keeps it compact; the full AirPlay-style
/// device list, status dots, and stats HUD arrive in Phase 4 (see docs/06).
struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "rectangle.on.rectangle")
                Text("Sidewire").font(.headline)
                Spacer()
            }
            Divider()

            if model.role == nil {
                Text("Choose a role to get started.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let source = model.source {
                SourceMenu(controller: source)
            } else if let display = model.display {
                DisplayMenu(controller: display)
            }

            Divider()
            HStack {
                Button("Open Sidewire") {
                    NSApp.activate(ignoringOtherApps: true) // bring the window forward in menu-bar-only mode
                    openWindow(id: "main")
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

private struct SourceMenu: View {
    @ObservedObject var controller: SourceController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(controller.statusText, systemImage: "dot.radiowaves.left.and.right")
                .font(.callout)
            if controller.peers.isEmpty {
                Text("Searching for displays…").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(controller.peers) { peer in
                    HStack {
                        Text(peer.name).font(.callout)
                        Spacer()
                        Button(controller.isConnected ? "Disconnect" : (controller.isConnecting ? "Connecting…" : "Connect")) {
                            controller.isConnected ? controller.disconnect() : controller.connect(to: peer)
                        }
                        .font(.caption)
                        .disabled(controller.isConnecting)
                    }
                }
            }
        }
    }
}

private struct DisplayMenu: View {
    @ObservedObject var controller: DisplayController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(controller.statusText, systemImage: "display")
                .font(.callout)
            if let src = controller.sourceName {
                Text("Connected to \(src)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
