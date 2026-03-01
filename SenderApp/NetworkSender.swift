import Foundation
import Network

final class NetworkSender: ObservableObject {
    private var connection: NWConnection?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.macdisplay.sender.network")

    @Published var isConnected = false
    @Published var statusMessage = "Disconnected"
    @Published var bytesSent: UInt64 = 0
    @Published var discoveredReceivers: [DiscoveredReceiver] = []
    @Published var bitrateKbps: Double = 0

    var onConnected: (() -> Void)?
    var onDisplayInfo: ((DisplayInfo) -> Void)?
    var onInputEvent: ((InputEvent) -> Void)?
    var onDisconnected: (() -> Void)?

    private var reconnectHost: String?
    private var reconnectPort: UInt16?
    private var shouldReconnect = false
    private var bytesInLastSecond: UInt64 = 0
    private var bitrateTimer: Timer?
    private let pendingLock = NSLock()
    private var _pendingSends = 0

    struct DiscoveredReceiver: Identifiable, Hashable {
        let id: String
        let name: String
        let endpoint: NWEndpoint

        static func == (lhs: DiscoveredReceiver, rhs: DiscoveredReceiver) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    func startBrowsing() {
        browser?.cancel()
        let params = NWParameters()
        params.includePeerToPeer = true
        browser = NWBrowser(for: .bonjour(type: kBonjourServiceType, domain: nil), using: params)

        browser?.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.startBrowsing()
                }
            }
        }

        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            let receivers = results.compactMap { result -> DiscoveredReceiver? in
                if case .service(let name, _, _, _) = result.endpoint {
                    return DiscoveredReceiver(id: name, name: name, endpoint: result.endpoint)
                }
                return nil
            }
            DispatchQueue.main.async {
                self?.discoveredReceivers = receivers
            }
        }

        browser?.start(queue: queue)
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }

    var selectedInterface: NWInterface?

    func connect(to host: String, port: UInt16 = kDefaultPort) {
        reconnectHost = host
        reconnectPort = port
        shouldReconnect = true

        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let conn = NWConnection(host: nwHost, port: nwPort, using: tcpParameters(interface: selectedInterface))
        setupConnection(conn)
    }

    func connect(to endpoint: NWEndpoint) {
        shouldReconnect = true
        reconnectHost = nil
        reconnectPort = nil
        let conn = NWConnection(to: endpoint, using: tcpParameters(interface: selectedInterface))
        setupConnection(conn)
    }

    private func setupConnection(_ conn: NWConnection) {
        connection?.cancel()
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.isConnected = true
                    self?.statusMessage = "Connected"
                    self?.onConnected?()
                    self?.startBitrateCounter()
                    if let c = self?.connection { self?.startReading(on: c) }
                case .failed(let error):
                    self?.isConnected = false
                    self?.statusMessage = "Failed: \(error.localizedDescription)"
                    self?.onDisconnected?()
                    self?.scheduleReconnect()
                case .waiting(let error):
                    self?.statusMessage = "Waiting: \(error.localizedDescription)"
                case .cancelled:
                    self?.isConnected = false
                    self?.statusMessage = "Disconnected"
                    self?.onDisconnected?()
                    self?.stopBitrateCounter()
                default:
                    break
                }
            }
        }

        conn.start(queue: queue)
    }

    func send(data: Data, type: PacketType = .videoFrame) {
        guard let connection, isConnected else { return }

        pendingLock.lock()
        _pendingSends += 1
        pendingLock.unlock()

        let header = PacketHeader(dataSize: UInt32(data.count), timestampMs: currentTimestampMs(), type: type)
        var packet = header.encodedData
        packet.append(data)

        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pendingLock.lock()
            self._pendingSends -= 1
            self.pendingLock.unlock()
            if let error {
                print("[Sender] Send error: \(error)")
            } else {
                self.bytesInLastSecond += UInt64(packet.count)
                DispatchQueue.main.async {
                    self.bytesSent += UInt64(packet.count)
                }
            }
        })
    }

    var pendingSends: Int {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return _pendingSends
    }

    func disconnect() {
        shouldReconnect = false
        connection?.cancel()
        connection = nil
        stopBitrateCounter()
    }

    private func startReading(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: kPacketHeaderSize, maximumLength: kPacketHeaderSize) { [weak self] data, _, isComplete, error in
            guard let data, let header = PacketHeader.decode(from: data) else {
                if !isComplete && error == nil { self?.startReading(on: connection) }
                return
            }
            self?.readPayload(on: connection, header: header)
        }
    }

    private func readPayload(on connection: NWConnection, header: PacketHeader) {
        let size = Int(header.dataSize)
        guard size > 0 else { startReading(on: connection); return }
        connection.receive(minimumIncompleteLength: size, maximumLength: size) { [weak self] data, _, isComplete, error in
            if let data {
                switch header.type {
                case .displayInfo:
                    if let info = DisplayInfo.decode(from: data) {
                        DispatchQueue.main.async { self?.onDisplayInfo?(info) }
                    }
                case .inputEvent:
                    if let event = InputEvent.decode(from: data) {
                        DispatchQueue.main.async { self?.onInputEvent?(event) }
                    }
                default:
                    break
                }
            }
            if !isComplete && error == nil { self?.startReading(on: connection) }
        }
    }

    private func scheduleReconnect() {
        guard shouldReconnect else { return }
        stopBitrateCounter()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.shouldReconnect else { return }
            self.statusMessage = "Reconnecting..."
            if let host = self.reconnectHost, let port = self.reconnectPort {
                self.connect(to: host, port: port)
            }
        }
    }

    private func startBitrateCounter() {
        bytesInLastSecond = 0
        bitrateTimer?.invalidate()
        bitrateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.bitrateKbps = Double(self.bytesInLastSecond * 8) / 1000.0
            self.bytesInLastSecond = 0
        }
    }

    private func stopBitrateCounter() {
        bitrateTimer?.invalidate()
        bitrateTimer = nil
        bitrateKbps = 0
    }
}
