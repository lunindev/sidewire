import SwiftUI
import AppKit
import AVFoundation

struct DisplayLayerRepresentable: NSViewRepresentable {
    let displayView: DisplayLayerView

    func makeNSView(context: Context) -> DisplayLayerView {
        displayView
    }

    func updateNSView(_ nsView: DisplayLayerView, context: Context) {}
}

struct ReceiverView: View {
    @StateObject private var receiver = NetworkReceiver()
    @State private var decoder = VideoDecoder()
    @State private var displayView = DisplayLayerView(frame: .zero)
    @State private var showStats = false
    @State private var inputCapture = InputCapture()
    @State private var inputEnabled = false
    @State private var isFullscreen = false
    @State private var showDisconnected = true
    @StateObject private var ifMonitor = InterfaceMonitor()
    @State private var selectedInterfaceName: String = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            DisplayLayerRepresentable(displayView: displayView)

            if showDisconnected {
                VStack(spacing: 12) {
                    Image(systemName: "display.trianglebadge.exclamationmark")
                        .font(.system(size: 48))
                        .foregroundStyle(.gray)
                    Text("Waiting for connection...")
                        .font(.title3)
                        .foregroundStyle(.gray)
                    if receiver.isListening {
                        Text("Listening on port \(kDefaultPort)")
                            .font(.caption)
                            .foregroundStyle(.gray.opacity(0.7))
                    }
                    Picker("Interface", selection: $selectedInterfaceName) {
                        Text("Any").tag("")
                        ForEach(ifMonitor.availableInterfaces) { iface in
                            Text(iface.label).tag(iface.name)
                        }
                    }
                    .frame(width: 250)
                    .onChange(of: selectedInterfaceName) { _, name in
                        receiver.selectedInterface = ifMonitor.availableInterfaces.first(where: { $0.name == name })?.nwInterface
                        receiver.stopListening()
                        receiver.startListening()
                    }
                }
            }

            if showStats {
                VStack {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(receiver.isConnected ? .green : (receiver.isListening ? .orange : .red))
                            .frame(width: 8, height: 8)
                        Text(receiver.statusMessage)
                        Spacer()
                        if receiver.isConnected {
                            Text("\(String(format: "%.0f", receiver.fps)) fps")
                            Text("\(receiver.lastLatencyMs)ms")
                            Text(formatBitrate(receiver.bitrateKbps))
                        }
                        if receiver.isListening {
                            Button("Stop") { receiver.stopListening() }
                        } else {
                            Button("Listen") { receiver.startListening() }
                        }
                    }
                    .font(.caption)
                    .padding(8)
                    .background(.black.opacity(0.7))
                    .foregroundStyle(.white)

                    Spacer()
                }
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .onAppear {
            setupDecoder()

            receiver.onSendDisplayInfo = {
                guard let screen = NSScreen.main else { return nil }
                let frame = screen.frame
                let scale = screen.backingScaleFactor
                return DisplayInfo(
                    width: Int(frame.width * scale),
                    height: Int(frame.height * scale),
                    refreshRate: 60,
                    scaleFactor: Double(scale),
                    name: screen.localizedName
                )
            }

            inputCapture.onInputEvent = { [weak receiver] event in
                guard let payload = event.encoded else { return }
                receiver?.send(data: payload, type: .inputEvent)
            }
            inputCapture.start()

            ifMonitor.start()
            receiver.startListening()

            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 {
                    exitImmersive()
                    return nil
                }
                return event
            }
        }
        .onChange(of: receiver.isConnected) { _, connected in
            if connected {
                resetForNewStream()
                showDisconnected = false
                enterImmersive()
            } else {
                showDisconnected = true
                exitImmersive()
                displayView.flush()
            }
        }
        .onTapGesture(count: 2) {
            showStats.toggle()
        }
    }

    private func setupDecoder() {
        decoder.onDecodedFrame = { sampleBuffer in
            DispatchQueue.main.async {
                displayView.enqueue(sampleBuffer)
            }
        }

        receiver.onFrameReceived = { data, packetType in
            let isKeyframe = packetType == .keyFrame
            decoder.decode(nalData: data, isKeyframe: isKeyframe)
        }
    }

    private func resetForNewStream() {
        decoder.invalidate()
        decoder = VideoDecoder()
        displayView.flush()
        setupDecoder()
    }

    private func enterImmersive() {
        if !isFullscreen {
            toggleFullscreen()
        }
        inputEnabled = true
        inputCapture.isEnabled = true
        showStats = false
    }

    private func exitImmersive() {
        inputEnabled = false
        inputCapture.isEnabled = false
        showStats = true
        if isFullscreen {
            toggleFullscreen()
        }
    }

    private func toggleFullscreen() {
        if let window = NSApp.keyWindow ?? NSApp.windows.first {
            window.toggleFullScreen(nil)
            isFullscreen.toggle()
            if isFullscreen {
                NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
            } else {
                NSApp.presentationOptions = []
            }
        }
    }

    private func formatBitrate(_ kbps: Double) -> String {
        if kbps > 1000 {
            return String(format: "%.1f Mbps", kbps / 1000)
        }
        return String(format: "%.0f Kbps", kbps)
    }
}
