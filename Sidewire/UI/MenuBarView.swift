import SwiftUI

/// The menu-bar popover surface. Phase 0 keeps it compact; the full AirPlay-style
/// device list, status dots, and stats HUD arrive in Phase 4 (see docs/06).
struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    // Phase 9 — surfaced here too so "Check for Updates…" stays reachable in menu-bar-only mode,
    // where the app's main menu (and its CommandGroup) is hidden.
    @EnvironmentObject var updater: UpdaterController
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
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
        // Fallback capture of the window opener (RootView captures it too) so a menu-bar-only
        // Display can resurface the main window when a Source connects.
        .onAppear { MainWindowOpener.open = { openWindow(id: "main") } }
    }
}

private struct SourceMenu: View {
    @ObservedObject var controller: SourceController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(controller.statusText, systemImage: "dot.radiowaves.left.and.right")
                .font(.callout)
            if controller.accessibilityRevoked {
                Label("Accessibility revoked — remote input disabled.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            }
            // Match the main window: connecting requires the full 6-digit PIN (an empty PIN
            // derives an empty PSK and silently fails the handshake).
            if !controller.isConnected && controller.pairingPIN.count != 6 {
                Text("Enter the 6-digit PIN in the main window to connect.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
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
                        .disabled(controller.isConnecting || (!controller.isConnected && controller.pairingPIN.count != 6))
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
            } else if controller.isListening {
                // Pairable: show the PIN here so menu-bar-only users can pair without opening
                // the main window.
                HStack(spacing: 6) {
                    Text("Pairing PIN").font(.caption).foregroundStyle(.secondary)
                    Text(controller.pairingPIN)
                        .font(.system(.callout, design: .monospaced)).fontWeight(.semibold)
                    Spacer()
                    Button("New PIN") { controller.rotatePIN() }
                        .font(.caption2)
                }
            } else {
                Text("Not accepting connections — open Sidewire to retry.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
