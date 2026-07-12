import Foundation
import Network
import SidewireProtocol

/// Accepts incoming connections (Display role) and advertises the service over
/// Bonjour on a known port. Each accepted connection is wrapped in a `TCPTransport`.
///
/// A single active connection is kept (newest wins; the Display role dedups above).
/// The listener auto-restarts on `.failed` after a short fixed backoff so a transient bind
/// or network failure (e.g. after the Mac sleeps) self-heals without user action — the
/// Display is a passive waiter that should always drift back to "listening".
public final class TCPListener: @unchecked Sendable {
    public var onConnection: ((TCPTransport) -> Void)?
    public var onState: ((String) -> Void)?
    /// Fired when the listener is bound, with the actual port (useful for tests / ephemeral).
    public var onReady: ((UInt16) -> Void)?

    private(set) public var boundPort: UInt16?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "sidewire.listener")
    private let serviceName: String

    /// Captured start parameters, replayed by the auto-restart path.
    private struct StartParams {
        let interface: NWInterface?
        let port: UInt16
        let advertise: Bool
        let identity: LocalIdentity
        let txt: [String: String]?
    }
    /// All of the following are touched only on `queue`, so start/stop and a queue-scheduled
    /// restart never race.
    private var params: StartParams?
    private var stopped = true
    /// Bumped by start()/stop(); a pending restart only fires while its captured generation
    /// still matches, so an explicit stop (or a fresh start) cancels an in-flight restart.
    private var generation = 0

    /// Backoff after a `.failed` state. Fixed and short — the Display is a passive waiter, so
    /// we retry indefinitely rather than ever give up.
    private static let restartDelay: TimeInterval = 1.0

    public init(serviceName: String) {
        self.serviceName = serviceName
    }

    /// Start listening. `port == 0` binds an OS-assigned ephemeral port. `advertise`
    /// controls Bonjour service advertisement (off for loopback tests). `identity` is this
    /// device's TLS identity, presented to every accepted connection (encryption is mandatory).
    public func start(interface: NWInterface? = nil,
                      port: UInt16 = ProtocolConstants.fallbackPort,
                      advertise: Bool = true,
                      identity: LocalIdentity,
                      txt: [String: String]? = nil) {
        let p = StartParams(interface: interface, port: port, advertise: advertise, identity: identity, txt: txt)
        queue.async {
            self.params = p
            self.stopped = false
            self.generation &+= 1
            self.bind(generation: self.generation)
        }
    }

    public func stop() {
        queue.async {
            self.stopped = true
            self.generation &+= 1 // cancels any pending restart dial
            self.teardown()
        }
    }

    // MARK: - Private (all on `queue`)

    private func bind(generation gen: Int) {
        guard !stopped, gen == generation, let p = params else { return }
        teardown() // never leave a prior NWListener running

        let nwParams = TCPTransport.tcpParameters(interface: p.interface, identity: p.identity)
        // Tolerate a lingering socket in TIME_WAIT / a fast restart on the same port.
        nwParams.allowLocalEndpointReuse = true

        let newListener: NWListener
        do {
            if p.port == 0 {
                newListener = try NWListener(using: nwParams)
            } else if let nwPort = NWEndpoint.Port(rawValue: p.port) {
                newListener = try NWListener(using: nwParams, on: nwPort)
            } else {
                newListener = try NWListener(using: nwParams)
            }
        } catch {
            onState?("listener error: \(error.localizedDescription)")
            coreLog.error("listener bind failed on port \(p.port): \(error.localizedDescription, privacy: .public)")
            scheduleRestart(after: gen) // a bind failure is usually transient (port busy after sleep)
            return
        }
        listener = newListener

        if p.advertise {
            var txtRecord: NWTXTRecord?
            if let txt = p.txt, !txt.isEmpty {
                var record = NWTXTRecord()
                for (k, v) in txt { record[k] = v }
                txtRecord = record
            }
            if let txtRecord {
                newListener.service = NWListener.Service(name: serviceName,
                                                         type: ProtocolConstants.bonjourServiceType,
                                                         txtRecord: txtRecord.data)
            } else {
                newListener.service = NWListener.Service(name: serviceName,
                                                         type: ProtocolConstants.bonjourServiceType)
            }
        }

        newListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let port = self.listener?.port?.rawValue ?? 0
                self.boundPort = port
                coreLog.info("listener ready on port \(port)")
                self.onState?("listening on port \(port)")
                self.onReady?(port)
            case .failed(let error):
                coreLog.error("listener failed: \(error.localizedDescription, privacy: .public)")
                self.onState?("failed: \(error.localizedDescription)")
                self.scheduleRestart(after: gen) // auto-heal (restart was deferred to Phase 1; now landed)
            case .cancelled:
                self.onState?("stopped")
            default:
                break
            }
        }

        newListener.newConnectionHandler = { [weak self] connection in
            // The accepted (Display/server) side: pass the identity for `ownSPKIHash` and mark
            // `isServer` so the channel-binding order is computed correctly.
            let transport = TCPTransport(connection: connection, label: "sidewire.transport.server",
                                         identity: p.identity, isServer: true)
            self?.onConnection?(transport)
        }

        newListener.start(queue: queue)
    }

    /// Re-arm after `.failed`, unless an explicit stop() (or a fresh start()) has since bumped
    /// the generation. Runs on `queue`; the delayed dial re-checks the guard.
    private func scheduleRestart(after gen: Int) {
        guard !stopped, gen == generation else { return }
        coreLog.notice("listener failed → restarting in \(String(format: "%.1f", TCPListener.restartDelay))s")
        queue.asyncAfter(deadline: .now() + TCPListener.restartDelay) { [weak self] in
            guard let self, !self.stopped, gen == self.generation else { return }
            self.bind(generation: gen)
        }
    }

    /// Detach handlers BEFORE cancelling so a re-arm never lets the old listener's late
    /// `.cancelled` deliver a stray "stopped" that clobbers state after the new listener has
    /// already reported "listening".
    private func teardown() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        boundPort = nil
    }
}
