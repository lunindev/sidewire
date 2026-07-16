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

    // Pairing disclosure. There is no PIN field until the user picks an unpaired Mac: clicking it
    // expands that row for the 6-digit code, and a Mac already paired connects in one click. This
    // replaces the old always-present PIN box that sat above the peer list — before you'd chosen
    // anyone — and the three Connect buttons that were dead until you filled it in.
    @State private var pairingPeerId: String?      // the row currently expanded for code entry
    @State private var pairingOverThunderbolt = false // that expansion targets the cable
    @State private var pinDraft = ""               // the code being typed in that row
    @FocusState private var pinFieldFocused: Bool

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
        .onChange(of: controller.isConnected) { _, connected in
            // A successful connect ends the pairing flow; the row becomes the connected row.
            if connected { collapsePairing() }
        }
        .onChange(of: controller.linkTarget) { _, target in
            // The link ended (target cleared) other than by success — e.g. a wrong code. Keep the
            // row expanded so the "code incorrect" hint lands where it was typed and the user can
            // retry; only collapse once there's nothing left to retry against.
            if target == nil, !controller.pinRejected { collapsePairing() }
        }
        .onChange(of: controller.peers) { _, peers in
            // The Mac we were entering a code for dropped off the network (slept, quit). Its row is
            // gone, so its pairing form — and any "code incorrect" hint — would be orphaned with
            // nowhere to render. Close it.
            if let id = pairingPeerId, controller.linkTarget == nil,
               !peers.contains(where: { $0.id == id }) {
                collapsePairing()
            }
        }
    }

    private func collapsePairing() {
        pairingPeerId = nil
        pairingOverThunderbolt = false
        pinDraft = ""
        // pinRejected is one controller-wide flag. Leaving it set after the pairing row closes
        // leaks its "Code incorrect" into the Connect-by-address section (whose error is gated on
        // pairingPeerId == nil). Safe for every caller: the success/normal-close paths already have
        // it false, and a fresh connect resets it in startLink.
        controller.pinRejected = false
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            if controller.accessibilityRevoked {
                accessibilityBanner
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
                            .onSubmit { dialManualHost() }
                        // A typed address has no advertised identity, so we can't tell ahead of the
                        // handshake whether it's already paired — the code sits right here with the
                        // address it belongs to. (It's ignored when the Mac turns out to be paired.)
                        if !controller.addressLinkActive {
                            TextField("code", text: $controller.pairingPIN)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .onChange(of: controller.pairingPIN) { _, newValue in
                                    let filtered = String(newValue.filter(\.isNumber).prefix(6))
                                    if filtered != newValue { controller.pairingPIN = filtered }
                                }
                        }
                        // The button belongs to THIS action: Cancel while this address is
                        // connecting, Disconnect once it's up (an address connect used to have a
                        // Disconnect nowhere in the whole window), Connect otherwise.
                        if controller.addressLinkActive {
                            Button(controller.isConnected ? "Disconnect" : "Cancel") { controller.disconnect() }
                        } else {
                            Button("Connect") { dialManualHost() }
                                .keyboardShortcut(.defaultAction)
                                .disabled(!canDialManualHost)
                        }
                    }
                    // Only when the failure was an address connect — a discovered-peer wrong code
                    // shows its error in that peer's expanded row instead (pairingPeerId set).
                    if controller.pinRejected, controller.linkTarget == nil, pairingPeerId == nil {
                        Label("Code incorrect — check the 6 digits shown on the other Mac.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.red)
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
                Label(controller.addressLinkActive ? "Connected by address — no other Macs found"
                        : (controller.searchedAWhileEmpty ? "No Macs found yet" : "Searching…"),
                      systemImage: controller.addressLinkActive ? "cable.connector" : "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if controller.discoveryLikelyBlocked && !controller.addressLinkActive {
                    // Discovery has been stuck with nothing found — almost always Local Network
                    // permission denied (Bonjour returns nothing when it's off). Suppressed under a
                    // live address connection, which already explains the empty list.
                    emptyStateHint(icon: "exclamationmark.triangle.fill", tint: .orange) {
                        Text("Local Network permission may be off — turn it on for Sidewire on both Macs.")
                            .font(.caption)
                        if let url = Permissions.localNetworkSettingsURL {
                            Link("Open Local Network settings", destination: url).font(.caption)
                        }
                    }
                } else if controller.searchedAWhileEmpty && !controller.addressLinkActive {
                    // The healthy-browser-but-empty case: the real reasons a Mac doesn't appear,
                    // none of which the browser can detect. This is the guidance that used to be
                    // missing entirely — the screen just said "Searching…" forever.
                    emptyStateHint(icon: "questionmark.circle", tint: .secondary) {
                        Text("Open Sidewire on your other Mac and choose **“Make this Mac the screen.”**")
                            .font(.caption)
                        Text("Both Macs must be on the same Wi-Fi, or joined by a Thunderbolt cable. A VPN can hide one from the other.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("On the cable? Use **Connect by address** below.")
                            .font(.caption).foregroundStyle(.secondary)
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

    /// A leading-icon guidance block for the empty discovered list.
    @ViewBuilder
    private func emptyStateHint<Content: View>(icon: String, tint: Color,
                                               @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) { content() }
        }
    }

    /// One row of the ConnectCard. `peer` is nil only for the orphan-active safety row (no live
    /// DiscoveredPeer to reconnect from), which is why it only ever shows Disconnect. An idle
    /// unpaired peer expands in place for the pairing code; a paired one connects in one click.
    @ViewBuilder
    private func peerRow(name: String, state: SourceController.RowState,
                         thunderbolt: String?, peer: DiscoveredPeer?) -> some View {
        let isExpanded = peer.map { pairingPeerId == $0.id } ?? false
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "display")
                Text(name)
                Spacer()
                rowControl(name: name, state: state, thunderbolt: thunderbolt,
                           peer: peer, isExpanded: isExpanded)
            }
            // The pairing code lives right under the Mac it belongs to, only while that row is
            // being paired and hasn't started connecting yet.
            if isExpanded, state == .idle, let peer {
                pairingForm(for: peer)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func rowControl(name: String, state: SourceController.RowState,
                            thunderbolt: String?, peer: DiscoveredPeer?, isExpanded: Bool) -> some View {
        switch state {
        case .connected:
            Button("Disconnect") { controller.disconnect() }
        case .connecting:
            Button("Cancel") { controller.disconnect() } // under the same cursor that started it
        case .idle where isExpanded:
            Button("Cancel") { collapsePairing() } // back out of pairing this Mac
        case .idle:
            // Thunderbolt quick-connect: only when nothing else is active and this Mac has a cable
            // bridge. For a paired peer it dials immediately; for an unpaired one it opens the code
            // form (remembering to use the cable when it connects).
            if let tb = thunderbolt, let peer, controller.localThunderboltIP != nil,
               controller.linkTarget == nil {
                Button {
                    beginConnect(peer, thunderbolt: true)
                } label: {
                    Label("Thunderbolt", systemImage: "cable.connector")
                }
                .tint(.green)
                .help("Connect over the Thunderbolt cable (\(tb))")
            }
            Button("Connect") { if let peer { beginConnect(peer, thunderbolt: false) } }
                // Never gated on the PIN — an unpaired Mac reveals the code field instead of
                // sitting dead. Only a link already active elsewhere disables it.
                .disabled(peer == nil || controller.linkTarget != nil)
        }
    }

    /// Start connecting to `peer`: a paired Mac needs no code and connects straight away; an
    /// unpaired one expands this row for the 6-digit code.
    private func beginConnect(_ peer: DiscoveredPeer, thunderbolt: Bool) {
        if controller.isPaired(peer) {
            collapsePairing() // a different row may have been mid-pairing; don't leave its form open
            controller.connect(to: peer, forceThunderbolt: thunderbolt)
        } else {
            controller.pinRejected = false
            pinDraft = ""
            pairingOverThunderbolt = thunderbolt
            pairingPeerId = peer.id // replaces any other expanded row (only one at a time)
            // Focus AFTER this mutation inserts the field — setting @FocusState in the same pass
            // that reveals the target view is a known SwiftUI no-op.
            DispatchQueue.main.async { pinFieldFocused = true }
        }
    }

    /// The inline pairing sub-form: the code field + Connect, and the "code incorrect" hint right
    /// where the code was typed (it used to live in a box 200pt above, phrased as a fact).
    @ViewBuilder
    private func pairingForm(for peer: DiscoveredPeer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Enter the 6-digit code shown on \(peer.name)")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("6-digit code", text: $pinDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                    .focused($pinFieldFocused)
                    .onChange(of: pinDraft) { _, newValue in
                        let filtered = String(newValue.filter(\.isNumber).prefix(6))
                        if filtered != newValue { pinDraft = filtered }
                    }
                    .onSubmit { commitPairing(peer) }
                Button("Connect") { commitPairing(peer) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pinDraft.count != 6)
            }
            if controller.pinRejected {
                Label("Code incorrect — check the 6 digits shown on \(peer.name).",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.leading, 24)
        .padding(.top, 2)
    }

    private func commitPairing(_ peer: DiscoveredPeer) {
        guard pinDraft.count == 6 else { return }
        controller.pairingPIN = pinDraft // startLink reads this to derive the pairing proof
        controller.connect(to: peer, forceThunderbolt: pairingOverThunderbolt)
        // Stay expanded: on success onChange collapses; on a wrong code the row keeps the field so
        // the user can fix it.
    }

    /// Dial the typed address, first closing any peer row that was mid-pairing — otherwise a wrong
    /// code from THIS address connect would be attributed to that still-expanded peer's row.
    private func dialManualHost() {
        guard canDialManualHost else { return }
        collapsePairing()
        controller.connect(manualAddress: manualHost)
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
                             (controller.currentBitrateMbps > 0 ? " · \(String(format: "%.0f", controller.currentBitrateMbps)) Mbps" : "") +
                             " · Encrypted") // honest now: tied to a live TLS link, not a field's length
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

