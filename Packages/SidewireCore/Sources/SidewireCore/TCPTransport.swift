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
    public var onInterface: ((String) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let parser = FrameParser()
    /// Whether this connection negotiates TLS-PSK — used to classify a pre-`.ready` failure
    /// as an authentication ("wrong PIN") error rather than a plain network problem.
    private let tlsEnabled: Bool
    /// Set on `.ready`; a failure after this is a normal drop, not a handshake/auth failure.
    private var reachedReady = false

    public init(connection: NWConnection, label: String = "sidewire.transport", tlsEnabled: Bool = false) {
        self.connection = connection
        self.queue = DispatchQueue(label: label)
        self.tlsEnabled = tlsEnabled
    }

    /// Dial a peer by host/port (manual-IP fallback path).
    public convenience init(host: String, port: UInt16, interface: NWInterface? = nil, psk: PSKCredential? = nil) {
        let params = Self.tcpParameters(interface: interface, psk: psk)
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port) ?? .init(integerLiteral: 5005),
                                using: params)
        self.init(connection: conn, tlsEnabled: psk != nil)
    }

    /// Dial a peer by discovered Bonjour endpoint (normal path).
    public convenience init(endpoint: NWEndpoint, interface: NWInterface? = nil, psk: PSKCredential? = nil) {
        let params = Self.tcpParameters(interface: interface, psk: psk)
        self.init(connection: NWConnection(to: endpoint, using: params), tlsEnabled: psk != nil)
    }

    public static func tcpParameters(interface: NWInterface?, psk: PSKCredential? = nil) -> NWParameters {
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
        let params = NWParameters(tls: psk.map { TLSPSK.options($0) }, tcp: tcp)
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
                self.reachedReady = true
                let iface = self.describeInterface()
                coreLog.info("transport READY via \(iface, privacy: .public)")
                self.onInterface?(iface)
                self.onState?(.ready)
                self.receiveLoop()
            case .waiting(let error):
                coreLog.notice("transport WAITING: \(error.localizedDescription, privacy: .public)")
                // A TLS-layer error while waiting to connect means the pre-shared key (PIN)
                // is wrong: retrying can never succeed, so fail fast with "auth" instead of
                // letting Network.framework spin until the connect timeout.
                if let reason = self.authReason(for: error) {
                    coreLog.error("transport TLS handshake failed (waiting) → \(reason, privacy: .public)")
                    self.onState?(.failed(reason))
                    self.connection.cancel()
                    return
                }
                self.onState?(.waiting(error.localizedDescription))
            case .failed(let error):
                coreLog.error("transport FAILED: \(error.localizedDescription, privacy: .public)")
                self.onState?(.failed(self.authReason(for: error) ?? error.localizedDescription))
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

    /// Classify a connection error as an authentication failure ("auth") when it is a
    /// TLS-layer error on a PSK connection that never reached `.ready` — i.e. the pairing
    /// PIN (and thus the derived pre-shared key) is wrong. A plain TCP refusal/unreachable
    /// is `NWError.posix` (e.g. ECONNREFUSED) and stays a normal transient/failure so a
    /// down-but-correct peer still auto-reconnects.
    private func authReason(for error: NWError) -> String? {
        guard tlsEnabled, !reachedReady else { return nil }
        if case .tls = error { return SessionConstants.authFailureReason }
        return nil
    }

    /// Best-effort description of the interface carrying this connection.
    private func describeInterface() -> String {
        guard let path = connection.currentPath else { return "unknown" }
        for iface in path.availableInterfaces where path.usesInterfaceType(iface.type) {
            switch iface.type {
            case .wifi: return "Wi-Fi"
            case .wiredEthernet:
                return iface.name.hasPrefix("bridge") ? "Thunderbolt (\(iface.name))" : "Ethernet (\(iface.name))"
            case .loopback: return "loopback"
            case .cellular: return "Cellular"
            default: return iface.name
            }
        }
        return "unknown"
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
