import Foundation
import Network
import os
import SidewireProtocol

/// Shared diagnostics logger for the networking core. Visible on both machines via:
///   log stream --predicate 'subsystem == "com.kinocoder.sidewire"'
let coreLog = Logger(subsystem: "com.kinocoder.sidewire", category: "net")

/// A `Transport` backed by a single `NWConnection` (TCP + certificate-based **TLS 1.3**). Used
/// both for the dialed client connection (Source) and for a connection accepted by
/// `TCPListener` (Display). Framing is handled here via `FrameEncoder` / `FrameParser`.
///
/// Encryption is non-optional: every real connection presents this device's identity and runs
/// TLS 1.3 (there is no plaintext path anymore — docs/10 E8). After `.ready` the peer's leaf
/// certificate is read from the TLS metadata to derive `TLSPeerInfo` (the pinned key, the
/// self-authenticating peer `deviceId`, and the pairing channel binding), and — on the dialing
/// side — to enforce public-key pinning against an expected peer ("keyChanged").
public final class TCPTransport: Transport, @unchecked Sendable {
    public var onFrame: ((Frame) -> Void)?
    public var onState: ((TransportState) -> Void)?
    public var onInterface: ((String) -> Void)?
    public var onSecurity: ((TLSPeerInfo) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let parser = FrameParser()
    /// This device's TLS identity (for `ownSPKIHash`; also baked into the connection params).
    private let identity: LocalIdentity?
    /// Dialing side only: the peer `deviceId` we expect (a paired peer). A mismatch between the
    /// presented key's derived id and this fails the link as "keyChanged".
    private let expectedPeerDeviceId: String?
    /// True on the accepted (Display/server) side; drives the client/server channel-binding order.
    private let isServer: Bool
    /// Set on `.ready`; a failure after this is a normal drop, not a handshake failure.
    private var reachedReady = false

    public init(connection: NWConnection, label: String = "sidewire.transport",
                identity: LocalIdentity? = nil, expectedPeerDeviceId: String? = nil,
                isServer: Bool = false) {
        self.connection = connection
        self.queue = DispatchQueue(label: label)
        self.identity = identity
        self.expectedPeerDeviceId = expectedPeerDeviceId
        self.isServer = isServer
    }

    /// Dial a peer by host/port (manual-IP fallback path).
    public convenience init(host: String, port: UInt16, interface: NWInterface? = nil,
                            identity: LocalIdentity, expectedPeerDeviceId: String? = nil) {
        let params = Self.tcpParameters(interface: interface, identity: identity)
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port) ?? .init(integerLiteral: 5005),
                                using: params)
        self.init(connection: conn, identity: identity, expectedPeerDeviceId: expectedPeerDeviceId)
    }

    /// Dial a peer by discovered Bonjour endpoint (normal path).
    public convenience init(endpoint: NWEndpoint, interface: NWInterface? = nil,
                            identity: LocalIdentity, expectedPeerDeviceId: String? = nil) {
        let params = Self.tcpParameters(interface: interface, identity: identity)
        self.init(connection: NWConnection(to: endpoint, using: params),
                  identity: identity, expectedPeerDeviceId: expectedPeerDeviceId)
    }

    public static func tcpParameters(interface: NWInterface?, identity: LocalIdentity) -> NWParameters {
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
        // Encryption is mandatory: always wrap in TLS 1.3 with this device's identity.
        let params = NWParameters(tls: TLS.options(identity: identity), tcp: tcp)
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
                // Derive the peer identity from the TLS leaf cert. On the dialing side, enforce
                // public-key pinning against the expected peer BEFORE surfacing .ready so no app
                // data ever flows to a changed key.
                if !self.publishSecurityContext() { return }
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

    /// Read the peer's leaf-certificate identity from the TLS metadata and fire `onSecurity`.
    /// Returns false (and fails the link) if pinning is violated ("keyChanged") — the caller
    /// must not proceed to `.ready` in that case. On a non-TLS connection (should not happen for
    /// a real transport) it simply proceeds with no security context.
    private func publishSecurityContext() -> Bool {
        guard let identity, let peerSPKI = TLS.peerLeafSPKIHash(of: connection) else {
            // No TLS metadata / identity: nothing to publish. Real connections always have both;
            // this only guards against an unexpected plaintext path.
            return true
        }
        let peerDeviceId = LocalIdentity.deviceId(fromSPKIHash: peerSPKI)
        if let expected = expectedPeerDeviceId, expected != peerDeviceId {
            coreLog.error("transport KEY CHANGED: expected \(expected, privacy: .public), got \(peerDeviceId, privacy: .public)")
            onState?(.failed(SessionConstants.keyChangedReason))
            connection.cancel()
            return false
        }
        let own = identity.spkiHash
        // Channel binding order is always client (Source/dialer) first, server (Display) second.
        let clientSPKI = isServer ? peerSPKI : own
        let serverSPKI = isServer ? own : peerSPKI
        let cb = PairingProof.channelBinding(clientSPKI: clientSPKI, serverSPKI: serverSPKI)
        onSecurity?(TLSPeerInfo(peerDeviceId: peerDeviceId, peerSPKIHash: peerSPKI,
                                ownSPKIHash: own, channelBinding: cb, isServer: isServer))
        return true
    }

    public func send(rawType: UInt8, flags: UInt8, seq: UInt32, payload: Data) {
        let data = FrameEncoder.encode(rawType: rawType, flags: flags, seq: seq, payload: payload)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    public func cancel() {
        connection.cancel()
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
