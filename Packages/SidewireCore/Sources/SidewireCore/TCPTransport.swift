import Foundation
import Network
import os
import SidewireProtocol

/// Shared diagnostics logger for the networking core. Visible on both machines via:
///   log stream --predicate 'subsystem == "com.kinocoder.sidewire"'
let coreLog = Logger(subsystem: "com.kinocoder.sidewire", category: "net")

/// A `Transport` backed by a single `NWConnection` (TCP). Used both for the
/// dialed client connection (Source) and for a connection accepted by `TCPListener`
/// (Display). Framing is handled here via `FrameEncoder` / `FrameParser`.
///
/// Phase 0 sets `noDelay`. Full keepalive / `connectionDropTime` tuning lands in Phase 1.
public final class TCPTransport: Transport, @unchecked Sendable {
    public var onFrame: ((Frame) -> Void)?
    public var onState: ((TransportState) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let parser = FrameParser()

    public init(connection: NWConnection, label: String = "sidewire.transport") {
        self.connection = connection
        self.queue = DispatchQueue(label: label)
    }

    /// Dial a peer by host/port (manual-IP fallback path).
    public convenience init(host: String, port: UInt16, interface: NWInterface? = nil) {
        let params = Self.tcpParameters(interface: interface)
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port) ?? .init(integerLiteral: 5005),
                                using: params)
        self.init(connection: conn)
    }

    /// Dial a peer by discovered Bonjour endpoint (normal path).
    public convenience init(endpoint: NWEndpoint, interface: NWInterface? = nil) {
        let params = Self.tcpParameters(interface: interface)
        self.init(connection: NWConnection(to: endpoint, using: params))
    }

    public static func tcpParameters(interface: NWInterface?) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // Backstop liveness (the app heartbeat is primary). connectionDropTime is the
        // critical one: a finite send timeout so a write to a vanished peer FAILS in
        // ~5s instead of retrying forever — the direct fix for the cable-pull hang.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = SessionConstants.tcpKeepaliveIdle
        tcp.keepaliveInterval = SessionConstants.tcpKeepaliveInterval
        tcp.keepaliveCount = SessionConstants.tcpKeepaliveCount
        tcp.connectionDropTime = SessionConstants.connectionDropTime
        let params = NWParameters(tls: nil, tcp: tcp)
        // NOTE: do NOT set includePeerToPeer here. On an outbound connection it makes
        // Network.framework attempt an AWDL peer-to-peer path, which stalls in .waiting
        // and drops on a normal Wi-Fi/Ethernet LAN. Peer-to-peer stays on the browser
        // (Discovery) only, matching the previous working app.
        if let interface { params.requiredInterface = interface }
        return params
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .setup, .preparing:
                self.onState?(.setup)
            case .ready:
                coreLog.info("transport READY")
                self.onState?(.ready)
                self.receiveLoop()
            case .waiting(let error):
                coreLog.notice("transport WAITING: \(error.localizedDescription, privacy: .public)")
                self.onState?(.waiting(error.localizedDescription))
            case .failed(let error):
                coreLog.error("transport FAILED: \(error.localizedDescription, privacy: .public)")
                self.onState?(.failed(error.localizedDescription))
            case .cancelled:
                coreLog.info("transport CANCELLED")
                self.onState?(.cancelled)
            @unknown default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func send(rawType: UInt8, flags: UInt8, seq: UInt32, payload: Data) {
        let data = FrameEncoder.encode(rawType: rawType, flags: flags, seq: seq, payload: payload)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    public func cancel() {
        connection.cancel()
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    let frames = try self.parser.append(data)
                    for f in frames { self.onFrame?(f) }
                } catch {
                    // Unrecoverable framing error → drop the connection.
                    self.onState?(.failed("framing: \(error)"))
                    self.connection.cancel()
                    return
                }
            }
            if let error {
                self.onState?(.failed(error.localizedDescription))
                return
            }
            if isComplete {
                self.onState?(.cancelled)
                return
            }
            self.receiveLoop()
        }
    }
}
