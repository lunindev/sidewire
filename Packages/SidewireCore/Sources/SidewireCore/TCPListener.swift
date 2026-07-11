import Foundation
import Network
import SidewireProtocol

/// Accepts incoming connections (Display role) and advertises the service over
/// Bonjour on a known port. Each accepted connection is wrapped in a `TCPTransport`.
///
/// Phase 0 keeps a single active connection (the newest wins). Multi-peer handling
/// and listener auto-restart come with the Phase 1 reliability engine.
public final class TCPListener: @unchecked Sendable {
    public var onConnection: ((TCPTransport) -> Void)?
    public var onState: ((String) -> Void)?
    /// Fired when the listener is bound, with the actual port (useful for tests / ephemeral).
    public var onReady: ((UInt16) -> Void)?

    private(set) public var boundPort: UInt16?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "sidewire.listener")
    private let serviceName: String

    public init(serviceName: String) {
        self.serviceName = serviceName
    }

    /// Start listening. `port == 0` binds an OS-assigned ephemeral port. `advertise`
    /// controls Bonjour service advertisement (off for loopback tests).
    public func start(interface: NWInterface? = nil,
                      port: UInt16 = ProtocolConstants.fallbackPort,
                      advertise: Bool = true,
                      psk: PSKCredential? = nil) {
        let params = TCPTransport.tcpParameters(interface: interface, psk: psk)
        // Tolerate a lingering socket in TIME_WAIT / a fast restart on the same port.
        params.allowLocalEndpointReuse = true

        do {
            if port == 0 {
                listener = try NWListener(using: params)
            } else if let nwPort = NWEndpoint.Port(rawValue: port) {
                listener = try NWListener(using: params, on: nwPort)
            } else {
                listener = try NWListener(using: params)
            }
        } catch {
            onState?("listener error: \(error.localizedDescription)")
            coreLog.error("listener bind failed on port \(port): \(error.localizedDescription, privacy: .public)")
            return
        }

        if advertise {
            listener?.service = NWListener.Service(name: serviceName,
                                                   type: ProtocolConstants.bonjourServiceType)
        }

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let p = self?.listener?.port?.rawValue ?? 0
                self?.boundPort = p
                coreLog.info("listener ready on port \(p)")
                self?.onState?("listening on port \(p)")
                self?.onReady?(p)
            case .failed(let error):
                coreLog.error("listener failed: \(error.localizedDescription, privacy: .public)")
                self?.onState?("failed: \(error.localizedDescription)")
            case .cancelled:
                self?.onState?("stopped")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            let transport = TCPTransport(connection: connection, label: "sidewire.transport.server")
            self?.onConnection?(transport)
        }

        listener?.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        boundPort = nil
    }
}
