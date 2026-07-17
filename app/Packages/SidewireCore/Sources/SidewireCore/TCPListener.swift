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

    /// The port we actually try to bind, i.e. the current rung of a deterministic port ladder.
    /// Starts at the requested (fixed) port; if that port is persistently held by another socket
    /// (EADDRINUSE — a zombie/duplicate app instance, or a same-process restart race that never
    /// clears), we step to the next rung (requested+1, +2, … up to `ladderSpan` ports, wrapping
    /// back to the requested port) until one binds — we never give up (the Display is a passive
    /// waiter). Every rung is a *concrete* port known BEFORE binding, so we advertise whichever
    /// one we bound in the Bonjour TXT (the "port" key): a discovered peer resolves it via mDNS,
    /// AND a host-based dial (the Thunderbolt one-click / manual IP / launch auto-connect) can read
    /// the advertised port and reach a non-standard rung too. Reset to the requested port on every
    /// fresh start(). When the requested port is 0 (an OS-ephemeral bind, used by tests/loopback)
    /// the ladder is disabled entirely: we just retry the ephemeral bind, and publish no "port".
    private var effectivePort: UInt16 = 0
    /// Consecutive EADDRINUSE failures on the *current* ladder rung. A same-process restart race
    /// clears within ~1 s (so we keep retrying the preferred rung that long); a foreign holder
    /// never releases, so after this many strikes we step to the next rung.
    private var addrInUseStrikes = 0
    private static let maxAddrInUseStrikes = 2
    /// Size of the deterministic port ladder: the requested port and the `ladderSpan - 1` ports
    /// above it (e.g. 5005…5012). Small — a busy machine shouldn't push the Display far from the
    /// well-known port — but enough headroom for a few stale/duplicate instances.
    private static let ladderSpan: UInt16 = 8

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
            // A fresh start re-tries the preferred fixed port from scratch (a prior fallback to
            // an ephemeral port shouldn't stick if the user re-arms and the port is free again).
            self.effectivePort = p.port
            self.addrInUseStrikes = 0
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
            if effectivePort == 0 {
                newListener = try NWListener(using: nwParams)
            } else if let nwPort = NWEndpoint.Port(rawValue: effectivePort) {
                newListener = try NWListener(using: nwParams, on: nwPort)
            } else {
                newListener = try NWListener(using: nwParams)
            }
        } catch {
            onState?("listener error: \(error.localizedDescription)")
            coreLog.error("listener bind failed on port \(self.effectivePort): \(error.localizedDescription, privacy: .public)")
            handleBindFailure(error, generation: gen) // a bind failure is usually transient (port busy after sleep)
            return
        }
        listener = newListener

        if p.advertise {
            // Advertise the port we actually bound under the TXT "port" key, MERGED with the
            // caller's TXT (which carries "did" and maybe "tb"). Because `effectivePort` is set
            // before every (re)bind and the service is rebuilt here, each ladder rung advertises
            // its own port with no chicken-and-egg and no post-`.ready` re-advertisement — a
            // discovered peer reads it to reach a non-standard rung (a host dial that can't see the
            // TXT falls back to `fallbackPort`). For an OS-ephemeral bind (params.port == 0) there
            // is no fixed port worth advertising, so we keep today's behavior and publish only the
            // caller TXT (or none).
            var merged: [String: String] = p.txt ?? [:]
            if p.port != 0 { merged["port"] = String(effectivePort) }
            if !merged.isEmpty {
                var record = NWTXTRecord()
                for (k, v) in merged { record[k] = v }
                newListener.service = NWListener.Service(name: serviceName,
                                                         type: ProtocolConstants.bonjourServiceType,
                                                         txtRecord: record.data)
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
                self.addrInUseStrikes = 0 // bound successfully — clear the EADDRINUSE strike count
                coreLog.info("listener ready on port \(port)")
                self.onState?("listening on port \(port)")
                self.onReady?(port)
            case .failed(let error):
                coreLog.error("listener failed: \(error.localizedDescription, privacy: .public)")
                self.onState?("failed: \(error.localizedDescription)")
                self.handleBindFailure(error, generation: gen) // auto-heal, incl. ephemeral fallback on a stuck port
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

    /// React to a bind/listen failure (sync throw or async `.failed`). For "address already in
    /// use" on the current rung we retry that rung a couple of times (a same-process restart race
    /// clears within ~1 s and we'd rather keep the well-known port), then step to the next ladder
    /// rung so a foreign holder (a leftover/duplicate instance) can no longer keep the Display off
    /// the air — the rung we end up on is advertised in the Bonjour TXT, so both discovered-peer
    /// and host-based connects still find us. Any other failure just re-arms on the current rung.
    /// Runs on `queue`.
    private func handleBindFailure(_ error: Error, generation gen: Int) {
        guard !stopped, gen == generation, let p = params else { return }
        // The ladder only applies to a real fixed port. For an OS-ephemeral bind (params.port == 0,
        // used by tests/loopback) there is no well-known port to preserve or advertise, so we keep
        // the plain "just retry" behavior and never enter the ladder.
        if p.port != 0, isAddressInUse(error) {
            addrInUseStrikes += 1
            if addrInUseStrikes >= TCPListener.maxAddrInUseStrikes {
                let next = nextLadderPort(after: effectivePort)
                coreLog.error("port \(self.effectivePort) is held by another process — advancing to ladder port \(next) (discovery resolves the new port via the Bonjour TXT)")
                onState?("port \(effectivePort) in use — trying port \(next)")
                effectivePort = next
                addrInUseStrikes = 0
                bind(generation: gen) // the next rung is usually free; no point waiting out the backoff
                return
            }
        }
        scheduleRestart(after: gen)
    }

    /// The next rung on the deterministic port ladder: advance by one, wrapping from the top rung
    /// (`base + ladderSpan - 1`) back to `base = params.port`. We never give up — the Display is a
    /// passive waiter, so a fully-busy ladder just cycles. Overflow-safe if `base` sits near the
    /// top of the port range. Only reached when `params.port != 0`.
    private func nextLadderPort(after port: UInt16) -> UInt16 {
        guard let base = params?.port, base != 0 else { return port } // ladder disabled for ephemeral
        let top = UInt16(min(UInt32(base) + UInt32(TCPListener.ladderSpan) - 1, UInt32(UInt16.max)))
        return port >= top ? base : port + 1
    }

    /// True for POSIX `EADDRINUSE` (error 48), the "port already bound" failure we recover from
    /// by stepping to the next ladder rung. Other `NWError`s fall through to a plain retry.
    private func isAddressInUse(_ error: Error) -> Bool {
        if let nwError = error as? NWError, case let .posix(code) = nwError {
            return code == .EADDRINUSE
        }
        return false
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
