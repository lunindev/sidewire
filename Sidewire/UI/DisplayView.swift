import SwiftUI
import AppKit

/// Display role: the immersive fullscreen video with an auto-hiding control bar. This Mac's
/// native cursor is the remote pointer — the Source no longer bakes a cursor into the video
/// (that round-trip is what made it feel laggy); instead it sends the cursor position on a
/// separate high-frequency channel and DisplayController warps the native cursor to it at
/// network latency. The control bar reveals on mouse movement and auto-hides; Esc always exits.
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
                if controller.isConnected, showExitToast {
                    Text("Press Esc to exit")
                        .font(.callout)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.bottom, 24)
                        .transition(.opacity)
                }
            }
        }
        .onContinuousHover { phase in
            if case .active = phase { revealControls() }
        }
        .onChange(of: controller.isConnected) { _, connected in
            if connected { enterImmersiveUI() } else { exitImmersiveUI() }
        }
        .onDisappear { hideWork?.cancel() }
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
            Button("Exit") { exitFullscreen() }
            Button("Switch role") { model.switchRole() }
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
            Text("⌘ shortcuts and Esc stay on this Mac (Esc exits fullscreen). Everything else is sent to the remote Mac.")
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
            Text(controller.isListening ? "Waiting for a Source…" : "Not accepting connections")
                .font(.title3).foregroundStyle(.gray)

            if controller.isListening {
                VStack(spacing: 4) {
                    Text("PAIRING PIN").font(.caption).tracking(2).foregroundStyle(.gray)
                    Text(controller.pairingPIN)
                        .font(.system(size: 44, weight: .semibold, design: .monospaced))
                        .tracking(6).foregroundStyle(.white)
                    Text("Enter this on the other Mac to connect")
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

            if controller.isListening {
                // The Source-side counterpart of SourceView's "Can't connect?" guide: the two
                // things that silently stop this Mac from being found/reached (backlog C1).
                VStack(spacing: 3) {
                    Text("Not seeing this Mac from the Source? Check Local Network permission and the firewall on this Mac.")
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

    /// Reveal the control bar on activity, then auto-hide while connected. The native cursor stays
    /// visible throughout — it is the remote pointer, driven by the Source's out-of-band cursor
    /// feed (DisplayController.warpCursor) rather than a cursor baked into the video.
    private func revealControls() {
        hideWork?.cancel()
        withAnimation { controlsVisible = true }
        guard controller.isConnected else { return }
        let work = DispatchWorkItem { withAnimation { controlsVisible = false } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func exitFullscreen() {
        (NSApp.keyWindow ?? NSApp.windows.first)?.toggleFullScreen(nil)
    }
}

/// Bridges the AppKit AVSampleBufferDisplayLayer host view into SwiftUI.
struct PresenterRepresentable: NSViewRepresentable {
    let view: VideoPresenterView
    func makeNSView(context: Context) -> VideoPresenterView { view }
    func updateNSView(_ nsView: VideoPresenterView, context: Context) {}
}
