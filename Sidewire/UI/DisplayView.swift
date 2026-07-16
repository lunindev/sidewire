import SwiftUI
import AppKit
import SidewireProtocol

/// Display role: the immersive fullscreen video with an auto-hiding control bar. This Mac's
/// native cursor is the remote pointer — the Source no longer bakes a cursor into the video
/// (that round-trip is what made it feel laggy); instead it sends the cursor position on a
/// separate high-frequency channel and DisplayController warps the native cursor to it at
/// network latency.
///
/// That warp is why `DisplayController.isGrabbed` gates this whole screen: while grabbed the
/// pointer belongs to the remote Mac, and Esc gives it back without dropping the stream. While
/// released the control bar stays pinned open — it's the one moment the user actually needs it.
struct DisplayView: View {
    @ObservedObject var controller: DisplayController
    @EnvironmentObject var model: AppModel

    @State private var controlsVisible = true
    @State private var showExitToast = false
    @State private var showInputHelp = false
    @State private var hideWork: DispatchWorkItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PresenterRepresentable(view: controller.presenter)

            if !controller.isConnected {
                waitingOverlay
            } else if controller.videoStalled {
                Color.black.opacity(0.55).ignoresSafeArea()
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("Reconnecting…").font(.title3).foregroundStyle(.white)
                }
            }

            VStack {
                if controlsVisible {
                    controlBar.transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                if controller.isGrabbed, showExitToast {
                    toast("Press Esc to get your mouse & keyboard back")
                } else if controller.canTakeControlByClicking {
                    // Persistent, not timed: the stream is live but this Mac's input goes nowhere,
                    // and nothing else on screen says so.
                    toast("Click the screen to control the other Mac")
                }
            }
        }
        .onContinuousHover { phase in
            if case .active = phase { revealControls() }
        }
        .onChange(of: controller.isConnected) { _, connected in
            if connected { enterImmersiveUI() } else { exitImmersiveUI() }
        }
        .onChange(of: controller.isGrabbed) { _, _ in
            // Releasing the pointer must surface the bar (that's where Disconnect lives); taking
            // the grab back re-arms the auto-hide.
            revealControls()
        }
        .onDisappear { hideWork?.cancel() }
    }

    private func toast(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.black.opacity(0.6), in: Capsule())
            .foregroundStyle(.white)
            .padding(.bottom, 24)
            .transition(.opacity)
    }

    private var controlBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(controller.isConnected ? .green : (controller.isListening ? .orange : .red))
                .frame(width: 8, height: 8)
            Text(controller.sourceName ?? controller.statusText).font(.caption)
            if controller.isConnected {
                Text("· \(Int(controller.presentedFps)) fps").font(.caption).foregroundStyle(.secondary)
                if !controller.streamResolution.isEmpty {
                    Text("· \(controller.streamResolution)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                showInputHelp.toggle()
            } label: {
                Image(systemName: "keyboard")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.white)
            .help("Keyboard & mouse")
            .popover(isPresented: $showInputHelp, arrowEdge: .bottom) {
                inputHelp
            }
            if controller.isGrabbed {
                Button("Release mouse & keyboard") { controller.releaseInput() }
                    .help("Give the pointer and keyboard back to this Mac (Esc). The stream keeps running.")
            }
            if controller.isConnected {
                Button("Disconnect") { controller.disconnect() }
            }
            Button("Change…") { model.switchRole() }
                .help("Choose whether this Mac is the main one or the extra screen.")
        }
        .padding(8)
        .background(.black.opacity(0.6))
        .foregroundStyle(.white)
    }

    /// What the local user keeps vs. what reaches the remote Mac (backlog C3). A compact popover,
    /// not a window — matches the "surfaces only when needed" onboarding style.
    private var inputHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Keyboard & mouse", systemImage: "keyboard")
                .font(.headline)
            Text("⌘ shortcuts and Esc stay on this Mac. Everything else is sent to the remote Mac.")
            Text("**Esc** gives your mouse & keyboard back to this Mac without stopping the stream. Click the screen to take control again.")
            Text("Non-US layouts: keys follow the remote Mac's layout.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .frame(width: 300, alignment: .leading)
        .padding(14)
    }

    private var waitingOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: controller.isListening ? "display.trianglebadge.exclamationmark" : "exclamationmark.triangle")
                .font(.system(size: 44)).foregroundStyle(.gray)
            Text(controller.isListening ? "Ready to be your extra screen" : "Not accepting connections")
                .font(.title3).foregroundStyle(.gray)

            if controller.isListening {
                VStack(spacing: 4) {
                    Text("PAIRING PIN").font(.caption).tracking(2).foregroundStyle(.gray)
                    Text(controller.pairingPIN)
                        .font(.system(size: 44, weight: .semibold, design: .monospaced))
                        .tracking(6).foregroundStyle(.white)
                    Text("Type this on your main Mac to connect")
                        .font(.caption2).foregroundStyle(.gray)
                    Button {
                        controller.rotatePIN()
                    } label: {
                        Label("New PIN", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.gray)
                    .padding(.top, 2)
                }
                .padding(.top, 4)
            } else {
                // The listener is down (e.g. a bind failure, or a stall after sleep). Show the
                // real state and a manual Retry instead of dangling a PIN as if pairable.
                Button {
                    controller.restartListener()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 2)
            }

            if controller.isListening, !controller.localAddresses.isEmpty {
                // This Mac's own IPs, so the main Mac's "Connect by address" field can be typed
                // straight off this screen instead of digging through System Settings. The
                // Thunderbolt link-local address is listed first (it's the cable path and can't
                // be guessed); a non-default listener port is appended as ":port".
                VStack(spacing: 4) {
                    Text("THIS MAC'S ADDRESS").font(.caption).tracking(2).foregroundStyle(.gray)
                    ForEach(controller.localAddresses) { addr in
                        HStack(spacing: 8) {
                            Text(addr.label)
                                .font(.caption).foregroundStyle(.gray)
                                .frame(width: 96, alignment: .trailing)
                            Text(addressText(addr))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.white)
                                .textSelection(.enabled)
                        }
                    }
                    Text("Type one of these into your main Mac's “Connect by address” field")
                        .font(.caption2).foregroundStyle(.gray)
                }
                .padding(.top, 4)
            }

            if controller.isListening {
                // The Source-side counterpart of SourceView's "Can't connect?" guide: the two
                // things that silently stop this Mac from being found/reached (backlog C1).
                VStack(spacing: 3) {
                    Text("Not seeing this Mac from your main Mac? Check Local Network permission and the firewall on this Mac.")
                        .multilineTextAlignment(.center)
                    if let url = Permissions.localNetworkSettingsURL {
                        Link("Open Local Network settings", destination: url)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.gray)
                .frame(maxWidth: 360)
                .padding(.top, 4)
            }

            Text(controller.statusText).font(.caption).foregroundStyle(.gray.opacity(0.7))
        }
    }

    /// The IP as the user should type it: bare, or "IP:port" when the listener bound a
    /// non-default port (the port-ladder fallback), so the manual connect targets the right one.
    private func addressText(_ addr: LocalAddress) -> String {
        if let port = controller.listeningPort, port != ProtocolConstants.fallbackPort {
            return "\(addr.ip):\(port)"
        }
        return addr.ip
    }

    // MARK: - Immersive UI behavior

    private func enterImmersiveUI() {
        showExitToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showExitToast = false }
        revealControls() // shows the bar, then auto-hides after a few seconds
    }

    private func exitImmersiveUI() {
        hideWork?.cancel()
        withAnimation { controlsVisible = true }
        showExitToast = false
    }

    /// Reveal the control bar on activity, then auto-hide — but only while the remote Mac owns the
    /// pointer. Once input is released the bar stays put: it holds Disconnect and the release
    /// state's only explanation, and hiding it would strand the user on a screen with no controls.
    private func revealControls() {
        hideWork?.cancel()
        withAnimation { controlsVisible = true }
        guard controller.isConnected, controller.isGrabbed else { return }
        let work = DispatchWorkItem { withAnimation { controlsVisible = false } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}

/// Bridges the AppKit AVSampleBufferDisplayLayer host view into SwiftUI.
struct PresenterRepresentable: NSViewRepresentable {
    let view: VideoPresenterView
    func makeNSView(context: Context) -> VideoPresenterView { view }
    func updateNSView(_ nsView: VideoPresenterView, context: Context) {}
}
