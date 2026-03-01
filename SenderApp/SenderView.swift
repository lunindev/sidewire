import SwiftUI
import CoreMedia

struct Resolution: Hashable, Identifiable {
    let width: UInt
    let height: UInt
    let label: String
    var id: String { "\(width)x\(height)" }
}

let kPresetResolutions: [Resolution] = [
    Resolution(width: 3456, height: 2234, label: "3456×2234 (16\" Retina)"),
    Resolution(width: 3024, height: 1964, label: "3024×1964 (14\" Retina)"),
    Resolution(width: 2560, height: 1600, label: "2560×1600 (16\" native)"),
    Resolution(width: 1920, height: 1200, label: "1920×1200"),
    Resolution(width: 1920, height: 1080, label: "1920×1080 (Full HD)"),
    Resolution(width: 1680, height: 1050, label: "1680×1050"),
    Resolution(width: 1440, height: 900, label: "1440×900"),
    Resolution(width: 1280, height: 800, label: "1280×800"),
]

let kFpsOptions = [30, 60]

struct SenderView: View {
    @StateObject private var sender = NetworkSender()
    @StateObject private var capture = ScreenCapture()
    @StateObject private var virtualDisplay = VirtualDisplay()
    @AppStorage("senderHostAddress") private var hostAddress = "169.254.1.1"
    @State private var selectedDisplay = 0
    @State private var isStreaming = false
    @State private var encoder: VideoEncoder?
    @AppStorage("senderUseVirtualDisplay") private var useVirtualDisplay = true
    @State private var selectedResolution = Resolution(width: 2560, height: 1600, label: "2560×1600 (16\" native)")
    @State private var receiverInfo: DisplayInfo?
    @AppStorage("senderFps") private var selectedFps = 60
    @AppStorage("senderConnectionMode") private var connectionModeRaw = 0
    @AppStorage("senderResWidth") private var savedResWidth = 2560
    @AppStorage("senderResHeight") private var savedResHeight = 1600
    @State private var inputInjector = InputInjector()
    @State private var inputForwardingEnabled = false
    @StateObject private var ifMonitor = InterfaceMonitor()
    @State private var selectedInterfaceName: String = ""
    @AppStorage("senderAdaptiveBitrate") private var adaptiveBitrate = true
    @State private var currentBitrate = 30_000_000
    @State private var adaptiveTimer: Timer?
    @State private var consecutiveCongested = 0
    @State private var consecutiveClear = 0
    private let minBitrate = 5_000_000
    private let maxBitrate = 50_000_000

    enum ConnectionMode: Int { case manual = 0, bonjour = 1 }
    private var connectionMode: ConnectionMode {
        get { ConnectionMode(rawValue: connectionModeRaw) ?? .manual }
    }

    private var allResolutions: [Resolution] {
        var list = kPresetResolutions
        if let info = receiverInfo {
            let r = Resolution(width: UInt(info.width), height: UInt(info.height), label: "\(info.width)×\(info.height) (\(info.name))")
            if !list.contains(where: { $0.width == r.width && $0.height == r.height }) {
                list.insert(r, at: 0)
            }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("MacDisplay Sender")
                .font(.title)

            HStack {
                Circle()
                    .fill(sender.isConnected ? .green : .red)
                    .frame(width: 12, height: 12)
                Text(sender.statusMessage)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Picker("Connection", selection: $connectionModeRaw) {
                        Text("Manual IP").tag(0)
                        Text("Auto-discover").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)

                    Picker("Interface", selection: $selectedInterfaceName) {
                        Text("Any").tag("")
                        ForEach(ifMonitor.availableInterfaces) { iface in
                            Text(iface.label).tag(iface.name)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                .onChange(of: connectionModeRaw) { _, mode in
                    if mode == 1 { sender.startBrowsing() }
                    else { sender.stopBrowsing() }
                }
                .onChange(of: selectedInterfaceName) { _, name in
                    sender.selectedInterface = ifMonitor.availableInterfaces.first(where: { $0.name == name })?.nwInterface
                }

                if connectionMode == .manual {
                    HStack {
                        TextField("Receiver IP", text: $hostAddress)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)

                        if sender.isConnected {
                            Button("Disconnect") {
                                Task { await stopStreaming() }
                                sender.disconnect()
                            }
                        } else {
                            Button("Connect") {
                                sender.connect(to: hostAddress)
                            }
                        }
                    }
                } else {
                    if sender.discoveredReceivers.isEmpty {
                        Text("Searching for receivers...")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    } else {
                        ForEach(sender.discoveredReceivers) { receiver in
                            HStack {
                                Text(receiver.name)
                                Spacer()
                                if sender.isConnected {
                                    Button("Disconnect") {
                                        Task { await stopStreaming() }
                                        sender.disconnect()
                                    }
                                    .font(.caption)
                                } else {
                                    Button("Connect") {
                                        sender.connect(to: receiver.endpoint)
                                    }
                                    .font(.caption)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
            }

            if let info = receiverInfo {
                Text("Receiver: \(info.name) \(info.width)×\(info.height) @\(Int(info.scaleFactor))x")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(spacing: 8) {
                HStack {
                    Circle()
                        .fill(virtualDisplay.isActive ? .green : .orange)
                        .frame(width: 10, height: 10)
                    Text("Virtual Display: \(virtualDisplay.statusMessage)")
                        .font(.caption)
                    Spacer()
                    if virtualDisplay.isActive {
                        Button("Destroy") {
                            virtualDisplay.destroy()
                            Task { await capture.fetchAvailableDisplays() }
                        }
                        .font(.caption)
                    }
                }

                HStack {
                    Picker("Resolution", selection: $selectedResolution) {
                        ForEach(allResolutions) { r in
                            Text(r.label).tag(r)
                        }
                    }
                    .frame(width: 300)

                    Button("Apply") {
                        guard !isStreaming else { return }
                        virtualDisplay.recreate(width: selectedResolution.width, height: selectedResolution.height)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            Task { await capture.fetchAvailableDisplays() }
                        }
                    }
                    .disabled(isStreaming || (virtualDisplay.width == selectedResolution.width && virtualDisplay.height == selectedResolution.height && virtualDisplay.isActive))
                    .font(.caption)
                }

                HStack {
                    Picker("FPS", selection: $selectedFps) {
                        ForEach(kFpsOptions, id: \.self) { fps in
                            Text("\(fps) fps").tag(fps)
                        }
                    }
                    .frame(width: 150)

                    Toggle("Virtual display", isOn: $useVirtualDisplay)
                        .disabled(!virtualDisplay.isActive)
                }

                HStack {
                    Toggle("Adaptive bitrate", isOn: $adaptiveBitrate)
                    if adaptiveBitrate {
                        Text("\(currentBitrate / 1_000_000) Mbps")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle()
                        .fill(inputForwardingEnabled ? .green : .gray)
                        .frame(width: 8, height: 8)
                    Text("Input: \(inputForwardingEnabled ? "Active" : "Off")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    if !capture.availableDisplays.isEmpty {
                        Picker("Display", selection: $selectedDisplay) {
                            ForEach(0..<capture.availableDisplays.count, id: \.self) { i in
                                let d = capture.availableDisplays[i]
                                Text("\(d.width)×\(d.height) (\(d.displayID))").tag(i)
                            }
                        }
                        .frame(width: 250)
                    }

                    Button("Refresh") {
                        Task { await capture.fetchAvailableDisplays() }
                    }
                }

                HStack {
                    if isStreaming {
                        Button("Stop Stream") {
                            Task { await stopStreaming() }
                        }
                    } else {
                        Button("Start Stream") {
                            Task { await startStreaming() }
                        }
                        .disabled(!sender.isConnected)
                    }
                }

                HStack(spacing: 12) {
                    Text("FPS: \(String(format: "%.0f", capture.fps))")
                    if sender.bitrateKbps > 0 {
                        Text(formatBitrate(sender.bitrateKbps))
                    }
                    Text(capture.captureStatus)
                        .foregroundStyle(.secondary)
                    if sender.bytesSent > 0 {
                        Text("\(sender.bytesSent / 1_000_000) MB")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
        .padding(24)
        .frame(minWidth: 550, minHeight: 480)
        .onAppear {
            ifMonitor.start()

            if let matched = kPresetResolutions.first(where: { $0.width == UInt(savedResWidth) && $0.height == UInt(savedResHeight) }) {
                selectedResolution = matched
            } else {
                selectedResolution = kPresetResolutions.first(where: { $0.width == 2560 && $0.height == 1600 }) ?? kPresetResolutions[0]
            }

            Task { await capture.fetchAvailableDisplays() }
            sender.onConnected = { [weak capture, weak virtualDisplay] in
                capture?.onSampleBuffer = nil
                if let vd = virtualDisplay, !vd.isActive {
                    vd.recreate(width: selectedResolution.width, height: selectedResolution.height)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        Task { [weak capture] in
                            await capture?.fetchAvailableDisplays()
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            await autoStartStreaming()
                        }
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        Task { [weak capture] in
                            await capture?.fetchAvailableDisplays()
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            await autoStartStreaming()
                        }
                    }
                }
            }
            sender.onDisplayInfo = { [weak virtualDisplay, weak capture] info in
                receiverInfo = info
                let matchRes = Resolution(width: UInt(info.width), height: UInt(info.height), label: "\(info.width)×\(info.height) (\(info.name))")
                selectedResolution = matchRes
                if let vd = virtualDisplay {
                    vd.recreate(width: matchRes.width, height: matchRes.height)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        Task { [weak capture] in
                            await capture?.fetchAvailableDisplays()
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            await autoStartStreaming()
                        }
                    }
                }
            }
            sender.onInputEvent = { [weak inputInjector = inputInjector] event in
                inputInjector?.inject(event: event)
            }
            sender.onDisconnected = { [weak virtualDisplay] in
                inputForwardingEnabled = false
                Task { await stopStreaming() }
                virtualDisplay?.destroy()
            }
            if connectionModeRaw == 1 { sender.startBrowsing() }
        }
        .onChange(of: selectedResolution) { _, res in
            savedResWidth = Int(res.width)
            savedResHeight = Int(res.height)
        }
        .onChange(of: isStreaming) { _, streaming in
            if streaming {
                inputInjector.virtualDisplayID = virtualDisplay.virtualDisplayID
                startAdaptiveTimer()
            } else {
                stopAdaptiveTimer()
            }
        }
    }

    private func autoStartStreaming() async {
        guard sender.isConnected, !isStreaming else { return }
        await startStreaming()
    }

    private func startStreaming() async {
        let targetDisplayID: CGDirectDisplayID? = useVirtualDisplay ? virtualDisplay.virtualDisplayID : nil

        let targetDisplay: (width: Int, height: Int)
        if useVirtualDisplay && virtualDisplay.isActive {
            targetDisplay = (Int(virtualDisplay.width), Int(virtualDisplay.height))
        } else if let targetDisplayID,
           let match = capture.availableDisplays.first(where: { $0.displayID == targetDisplayID }) {
            targetDisplay = (match.width, match.height)
        } else if !capture.availableDisplays.isEmpty {
            let d = capture.availableDisplays[selectedDisplay]
            targetDisplay = (d.width, d.height)
        } else {
            return
        }

        let enc = VideoEncoder(width: Int32(targetDisplay.width), height: Int32(targetDisplay.height), fps: selectedFps)
        encoder = enc

        enc.forceKeyframe()

        enc.onEncodedFrame = { [weak sender] data, isKey in
            sender?.send(data: data, type: isKey ? .keyFrame : .videoFrame)
        }

        capture.onSampleBuffer = { [weak enc] sampleBuffer in
            guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            enc?.encode(pixelBuffer: pixelBuffer, presentationTime: pts)
        }

        let pixW = useVirtualDisplay ? Int(virtualDisplay.width) : nil
        let pixH = useVirtualDisplay ? Int(virtualDisplay.height) : nil
        await capture.startCapture(displayIndex: selectedDisplay, displayID: targetDisplayID, fps: selectedFps, pixelWidth: pixW, pixelHeight: pixH)
        isStreaming = true
    }

    private func stopStreaming() async {
        await capture.stopCapture()
        encoder?.flush()
        encoder?.invalidate()
        encoder = nil
        isStreaming = false
    }

    private func formatBitrate(_ kbps: Double) -> String {
        if kbps > 1000 {
            return String(format: "%.1f Mbps", kbps / 1000)
        }
        return String(format: "%.0f Kbps", kbps)
    }

    private func startAdaptiveTimer() {
        stopAdaptiveTimer()
        guard adaptiveBitrate else { return }
        consecutiveCongested = 0
        consecutiveClear = 0
        adaptiveTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            guard isStreaming, adaptiveBitrate, capture.fps > 5 else { return }

            let pending = sender.pendingSends
            if pending > 5 {
                consecutiveCongested += 1
                consecutiveClear = 0
                if consecutiveCongested >= 2 {
                    currentBitrate = max(minBitrate, currentBitrate * 70 / 100)
                    encoder?.updateBitrate(currentBitrate)
                    consecutiveCongested = 0
                }
            } else if pending < 2 {
                consecutiveClear += 1
                consecutiveCongested = 0
                if consecutiveClear >= 3 {
                    currentBitrate = min(maxBitrate, currentBitrate * 115 / 100)
                    encoder?.updateBitrate(currentBitrate)
                    consecutiveClear = 0
                }
            } else {
                consecutiveCongested = max(0, consecutiveCongested - 1)
                consecutiveClear = max(0, consecutiveClear - 1)
            }
        }
    }

    private func stopAdaptiveTimer() {
        adaptiveTimer?.invalidate()
        adaptiveTimer = nil
    }
}
