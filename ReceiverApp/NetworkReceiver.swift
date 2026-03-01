import Foundation
import Network

final class NetworkReceiver: ObservableObject {
    private var listener: NWListener?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.macdisplay.receiver.network")

    @Published var isListening = false
    @Published var isConnected = false
    @Published var statusMessage = "Idle"
    @Published var packetsReceived: Int = 0
    @Published var lastLatencyMs: UInt64 = 0
    @Published var fps: Double = 0
    @Published var bytesReceived: UInt64 = 0
    @Published var bitrateKbps: Double = 0

    var onFrameReceived: ((Data, PacketType) -> Void)?
    var onSendDisplayInfo: (() -> DisplayInfo?)?
    var selectedInterface: NWInterface?

    private var frameCount = 0
    private var fpsTimer: Timer?
    private var bytesInLastSecond: UInt64 = 0

    func startListening(port: UInt16 = kDefaultPort) {
        do {
            let nwPort = NWEndpoint.Port(rawValue: port)!
            listener = try NWListener(using: tcpParameters(interface: selectedInterface), on: nwPort)
        } catch {
            DispatchQueue.main.async {
                self.statusMessage = "Listener error: \(error.localizedDescription)"
            }
            return
        }

        listener?.service = NWListener.Service(name: "MacDisplay", type: kBonjourServiceType)

        listener?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.isListening = true
                    self?.statusMessage = "Listening on port \(port)"
                case .failed(let error):
                    self?.isListening = false
                    self?.statusMessage = "Listener failed: \(error.localizedDescription)"
                    self?.restartListener(port: port)
                case .cancelled:
                    self?.isListening = false
                    self?.statusMessage = "Stopped"
                default:
                    break
                }
            }
        }

        listener?.newConnectionHandler = { [weak self] newConnection in
            self?.connection?.cancel()
            self?.connection = newConnection
            DispatchQueue.main.async {
                self?.isConnected = true
                self?.statusMessage = "Client connected"
                self?.startFPSCounter()
            }
            self?.setupReceive(on: newConnection)
            newConnection.start(queue: self?.queue ?? .main)
            self?.sendDisplayInfo(on: newConnection)
        }

        listener?.start(queue: queue)
    }

    func stopListening() {
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        fpsTimer?.invalidate()
        fpsTimer = nil
    }

    private func restartListener(port: UInt16) {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.statusMessage = "Restarting listener..."
            self?.startListening(port: port)
        }
    }

    func send(data: Data, type: PacketType) {
        guard let connection else { return }
        let header = PacketHeader(dataSize: UInt32(data.count), timestampMs: currentTimestampMs(), type: type)
        var packet = header.encodedData
        packet.append(data)
        connection.send(content: packet, completion: .contentProcessed { error in
            if let error { print("[Receiver] Send error: \(error)") }
        })
    }

    private func sendDisplayInfo(on connection: NWConnection) {
        guard let info = onSendDisplayInfo?(), let payload = info.encoded else { return }
        let header = PacketHeader(dataSize: UInt32(payload.count), timestampMs: currentTimestampMs(), type: .displayInfo)
        var packet = header.encodedData
        packet.append(payload)
        connection.send(content: packet, completion: .contentProcessed { error in
            if let error { print("[Receiver] Failed to send display info: \(error)") }
        })
    }

    private func setupReceive(on connection: NWConnection) {
        readHeader(on: connection)
    }

    private func readHeader(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: kPacketHeaderSize, maximumLength: kPacketHeaderSize) { [weak self] data, _, isComplete, error in
            if let error {
                self?.handleDisconnect(error: error)
                return
            }

            if isComplete {
                self?.handleDisconnect(error: nil)
                return
            }

            guard let data, let header = PacketHeader.decode(from: data) else {
                self?.readHeader(on: connection)
                return
            }

            self?.readPayload(on: connection, header: header)
        }
    }

    private func readPayload(on connection: NWConnection, header: PacketHeader) {
        let size = Int(header.dataSize)
        guard size > 0 else {
            readHeader(on: connection)
            return
        }

        connection.receive(minimumIncompleteLength: size, maximumLength: size) { [weak self] data, _, isComplete, error in
            if let error {
                self?.handleDisconnect(error: error)
                return
            }

            if let data {
                self?.handlePacket(data: data, header: header)
            }

            if isComplete {
                self?.handleDisconnect(error: nil)
                return
            }

            self?.readHeader(on: connection)
        }
    }

    private func handlePacket(data: Data, header: PacketHeader) {
        let now = currentTimestampMs()
        let latency = now >= header.timestampMs ? now - header.timestampMs : 0
        frameCount += 1
        bytesInLastSecond += UInt64(data.count)

        onFrameReceived?(data, header.type)

        DispatchQueue.main.async {
            self.packetsReceived += 1
            self.bytesReceived += UInt64(data.count)
            self.lastLatencyMs = latency
        }
    }

    private func handleDisconnect(error: NWError?) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.fpsTimer?.invalidate()
            self.fpsTimer = nil
            self.fps = 0
            self.bitrateKbps = 0
            if let error {
                self.statusMessage = "Disconnected: \(error.localizedDescription)"
            } else {
                self.statusMessage = "Client disconnected, waiting for reconnect..."
            }
        }
    }

    private func startFPSCounter() {
        frameCount = 0
        bytesInLastSecond = 0
        fpsTimer?.invalidate()
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.fps = Double(self.frameCount)
            self.bitrateKbps = Double(self.bytesInLastSecond * 8) / 1000.0
            self.frameCount = 0
            self.bytesInLastSecond = 0
        }
    }
}
