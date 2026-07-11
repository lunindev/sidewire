import SwiftUI
import AppKit

/// Display role main window: hosts the decoded video and a waiting/overlay state.
/// Phase 0 shows the stream in a window; the immersive fullscreen experience with an
/// auto-hiding control bar is Phase 4 (see docs/06).
struct DisplayView: View {
    @ObservedObject var controller: DisplayController
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PresenterRepresentable(view: controller.presenter)

            if !controller.isConnected {
                VStack(spacing: 14) {
                    Image(systemName: "display.trianglebadge.exclamationmark")
                        .font(.system(size: 44))
                        .foregroundStyle(.gray)
                    Text(controller.isListening ? "Waiting for a Source…" : "Not listening")
                        .font(.title3)
                        .foregroundStyle(.gray)
                    VStack(spacing: 4) {
                        Text("PAIRING PIN")
                            .font(.caption).tracking(2).foregroundStyle(.gray)
                        Text(controller.pairingPIN)
                            .font(.system(size: 44, weight: .semibold, design: .monospaced))
                            .tracking(6)
                            .foregroundStyle(.white)
                        Text("Enter this on the other Mac to connect")
                            .font(.caption2).foregroundStyle(.gray)
                    }
                    .padding(.top, 4)
                    Text(controller.statusText)
                        .font(.caption)
                        .foregroundStyle(.gray.opacity(0.7))
                }
            } else if controller.videoStalled {
                // Connected but no frames — dim the last frame and say so, never a bare freeze.
                Color.black.opacity(0.55).ignoresSafeArea()
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("Reconnecting…")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
            }

            VStack {
                HStack(spacing: 10) {
                    Circle()
                        .fill(controller.isConnected ? .green : (controller.isListening ? .orange : .red))
                        .frame(width: 8, height: 8)
                    Text(controller.sourceName ?? controller.statusText)
                        .font(.caption)
                    if controller.isConnected {
                        Text("· \(Int(controller.presentedFps)) fps")
                            .font(.caption).foregroundStyle(.secondary)
                        if !controller.streamResolution.isEmpty {
                            Text("· \(controller.streamResolution)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Fullscreen") { toggleFullscreen() }
                    Button("Switch role") { model.switchRole() }
                }
                .padding(8)
                .background(.black.opacity(0.55))
                .foregroundStyle(.white)
                Spacer()
            }
        }
    }

    private func toggleFullscreen() {
        (NSApp.keyWindow ?? NSApp.windows.first)?.toggleFullScreen(nil)
    }
}

/// Bridges the AppKit AVSampleBufferDisplayLayer host view into SwiftUI.
struct PresenterRepresentable: NSViewRepresentable {
    let view: VideoPresenterView
    func makeNSView(context: Context) -> VideoPresenterView { view }
    func updateNSView(_ nsView: VideoPresenterView, context: Context) {}
}
