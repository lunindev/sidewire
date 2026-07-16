import SwiftUI
import SidewireCore
import SidewireProtocol // Address.parse — validates the manual-connect field before dialling

/// The Main Mac's window: find the spare Mac, connect, and see how the extra screen is doing.
///
/// Permissions are NOT here — they're a gate (PermissionsGateView) the user passes before this screen
/// exists, so this screen is only ever about connecting. Quality lives in Settings (⌘,) and the
/// virtual-display readout moved to Settings ▸ Diagnostics: both were engineering panels sitting
/// under the connect controls with equal visual weight, which is what made this look like a
/// debug console rather than a product.
struct SourceView: View {
    @ObservedObject var controller: SourceController
    @EnvironmentObject var model: AppModel
    @State private var manualHost = SourceController.lastHost

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            Divider()
            // Everything below scrolls. Without this the column simply overflowed the window and
            // SwiftUI centred it, rendering the header at a negative y — the status, Cancel and
            // Switch role were not drawn at all.
            ScrollView {
                content.padding(24)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            if controller.accessibilityRevoked {
                accessibilityBanner
            }

            GroupBox("PIN (shown on your other Mac)") {
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
                        // Gated on a real connection, not on the text field's length. Six digits
                        // typed into a box encrypt nothing, and the PIN persists across launches —
                        // so the old check lit this green on a cold start before anything had
                        // connected, and again directly above "PIN incorrect".
                        if controller.isConnected {
                            Label("Encrypted (TLS)", systemImage: "lock.fill")
                                .font(.caption).foregroundStyle(.green)
                        } else if controller.pairingPIN.count < 6 {
                            Text("Enter the PIN shown on your other Mac.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    if controller.pinRejected {
                        Label("PIN incorrect — check the code shown on your other Mac.",
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

            GroupBox("Macs that can be your screen") {
                HStack {
                    InterfacePicker(controller: controller, monitor: controller.interfaceMonitor)
                        .frame(maxWidth: 240)
                    Spacer()
                    Button {
                        controller.refreshDiscovery()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    // Refresh wipes the list before re-scanning; doing that while a link is up would
                    // yank the connected row (and its Disconnect) out from under the user.
                    .disabled(controller.linkTarget != nil)
                }
                .padding(.bottom, 4)
                Divider()

                peerList
            }

            // "Connect by address" — NOT "forces Thunderbolt", which was simply false:
            // connect(host:port:) never sets params.requiredInterface, so the route is whatever
            // the routing table picks for the address typed. It only goes over the cable if you
            // type the cable's 169.254.x.x — and the other Mac openly offers its Wi-Fi address
            // for this field too.
            GroupBox("Connect by address") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("169.254.x.x[:port]", text: $manualHost)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            .disabled(controller.linkTarget != nil)
                            .onSubmit { if canDialManualHost { controller.connect(manualAddress: manualHost) } }
                        // The button belongs to THIS action: Cancel while this address is
                        // connecting, Disconnect once it's up (an address connect used to have a
                        // Disconnect nowhere in the whole window), Connect otherwise.
                        if controller.addressLinkActive {
                            Button(controller.isConnected ? "Disconnect" : "Cancel") { controller.disconnect() }
                        } else {
                            Button("Connect") { controller.connect(manualAddress: manualHost) }
                                .keyboardShortcut(.defaultAction)
                                .disabled(!canDialManualHost)
                        }
                    }
                    // Refuse a malformed address here rather than dial it. Anything unparseable
                    // used to be handed to the network stack verbatim, fail as a "transient" DNS
                    // error, and be retried indefinitely — a stray space cost two minutes and then
                    // blamed the other Mac.
                    if !manualHost.trimmingCharacters(in: .whitespaces).isEmpty,
                       Address.parse(manualHost) == nil {
                        Label("That isn't an address Sidewire can dial. Try 169.254.3.4 or 169.254.3.4:5006.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let tb = controller.localThunderboltIP {
                        Label("Thunderbolt cable detected (this Mac: \(tb)). Enter the OTHER Mac's 169.254.x.x to go over the cable.",
                              systemImage: "cable.connector")
                            .font(.caption2).foregroundStyle(.green)
                    } else {
                        Text("No Thunderbolt Bridge found — connect a cable and check System Settings → Network.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    // The Display normally binds 5005, but steps to 5006, 5007, … if that port is
                    // taken (it shows the bound port in its status). If it shows a non-standard
                    // port, append it here, e.g. 169.254.3.4:5006.
                    Text("Tip: if the other Mac shows a non-standard port, append it — e.g. 169.254.3.4:5006.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            // After both ways of connecting, not wedged between them — sitting in the middle made
            // the address field read as part of the troubleshooting rather than as the fallback
            // path it is.
            troubleshooting

            // Quality used to be duplicated here, with a disable rule that contradicted its twin
            // in Settings (here: locked while connected; there: editable, with a Reconnect button
            // that applies it live). One control, one home — Settings.
            HStack {
                SettingsLink {
                    Label("Screen quality & other settings…", systemImage: "slider.horizontal.3")
                }
                Spacer()
            }
            .font(.callout)
        }
    }

    /// The discovered-Macs list. Each row derives its own state from the controller's `linkTarget`,
    /// so exactly one row is ever "connecting"/"connected" and the rest stay plain "Connect".
    @ViewBuilder
    private var peerList: some View {
        // A peer we're connected to that discovery has since dropped from its list would take its
        // Disconnect with it — so if the active peer target isn't in `peers`, keep a row for it.
        let activePeerId: String? = {
            if case .peer(let id) = controller.linkTarget { return id }
            return nil
        }()
        let orphanActive = activePeerId != nil && !controller.peers.contains { $0.id == activePeerId }

        if controller.peers.isEmpty && !orphanActive {
            VStack(alignment: .leading, spacing: 6) {
                // When connected by a typed address, discovery genuinely found nothing on the
                // network — but "Searching…" alone next to a live connection reads as broken, so
                // say what's actually true.
                Label(controller.addressLinkActive ? "Connected by address — no other Macs found" : "Searching…",
                      systemImage: controller.addressLinkActive ? "cable.connector" : "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if controller.discoveryLikelyBlocked {
                    // Discovery has been stuck with nothing found — almost always Local Network
                    // permission denied (Bonjour returns nothing when it's off).
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No Macs found. Local Network permission may be off — turn it on for Sidewire on both Macs.")
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
                if orphanActive {
                    peerRow(name: controller.peerName ?? String(localized: "Connected Mac"),
                            state: controller.rowState(forPeerId: activePeerId!), thunderbolt: nil, peer: nil)
                    Divider()
                }
                ForEach(controller.peers) { peer in
                    peerRow(name: peer.name,
                            state: controller.rowState(forPeerId: peer.id),
                            thunderbolt: peer.thunderboltIP, peer: peer)
                    Divider()
                }
            }
        }
    }

    /// One row. `peer` is nil only for the orphan-active safety row (no live DiscoveredPeer to
    /// reconnect from), which is why its buttons are limited to Disconnect.
    @ViewBuilder
    private func peerRow(name: String, state: SourceController.RowState,
                         thunderbolt: String?, peer: DiscoveredPeer?) -> some View {
        HStack {
            Image(systemName: "display")
            Text(name)
            Spacer()
            switch state {
            case .idle:
                // Thunderbolt quick-connect: only when nothing else is active, and only if this
                // Mac has a cable bridge to route over.
                if let tb = thunderbolt, let peer, controller.localThunderboltIP != nil,
                   controller.linkTarget == nil {
                    Button {
                        controller.connect(to: peer, forceThunderbolt: true)
                    } label: {
                        Label("Thunderbolt", systemImage: "cable.connector")
                    }
                    .tint(.green)
                    .disabled(controller.pairingPIN.count != 6)
                    .help("Connect over the Thunderbolt cable (\(tb))")
                }
                Button("Connect") { if let peer { controller.connect(to: peer) } }
                    // A link elsewhere is up/connecting, or no PIN yet → can't start this one.
                    .disabled(peer == nil || controller.linkTarget != nil || controller.pairingPIN.count != 6)
            case .connecting:
                Button("Cancel") { controller.disconnect() } // under the same cursor that started it
            case .connected:
                Button("Disconnect") { controller.disconnect() }
            }
        }
        .padding(.vertical, 6)
    }

    /// The address has to parse before the button lights up — same parse the controller performs,
    /// so the button can never be enabled for something that would be silently rejected. Gated on
    /// linkTarget (not just the bools): startLink sets linkTarget synchronously but isConnecting
    /// only flips a runloop hop later, so without this the button lags one frame behind the field.
    private var canDialManualHost: Bool {
        Address.parse(manualHost) != nil
            && controller.linkTarget == nil
            && controller.pairingPIN.count == 6
    }

    /// Pinned above the scroll area, so it can never be pushed out of the window the way it was
    /// when the whole screen was one overflowing column.
    private var header: some View {
        HStack {
            Circle()
                .fill(controller.isConnected ? .green : .secondary)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text("Main Mac").font(.headline)
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
            // No Cancel/Disconnect here any more — it lives at the row or address field that
            // started the connection, so the control is under the same cursor as the action.
            Button("Change…") { model.switchRole() }
                .help("Choose whether this Mac is the main one or the extra screen.")
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
                    Text("**Firewall.** The macOS firewall on your other Mac (System Settings › Network › Firewall) can block incoming connections — allow Sidewire there. \u{201C}Connect by address\u{201D} needs this too.")
                }
                TroubleRow(icon: "wifi") {
                    Text("**Same network.** Both Macs must be on the same Wi-Fi/LAN; a VPN can isolate them. A Thunderbolt cable is the reliable fallback.")
                }
                TroubleRow(icon: "arrow.2.squarepath") {
                    Text("**Which Mac is which.** Your other Mac must be set to \u{201C}Make this Mac the screen\u{201D}. If both Macs are set to be the main one, this list stays empty.")
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

/// The virtual-display readout. Engineering diagnostics ("Active · helper (ID 12)"), so it lives
/// in Settings ▸ Diagnostics rather than nailed under the connect controls forever, where it had
/// the same visual weight as the primary action.
struct VirtualDisplayStatusView: View {
    @ObservedObject var vd: VirtualDisplayManager
    @ObservedObject var capture: ScreenCapture
    let isStreaming: Bool

    var body: some View {
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

