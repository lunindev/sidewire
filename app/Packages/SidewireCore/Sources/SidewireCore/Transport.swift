import Foundation
import SidewireProtocol

/// Connection-level state, surfaced from the underlying `NWConnection`.
public enum TransportState: Sendable, Equatable {
    case setup
    case ready
    case waiting(String)
    case failed(String)
    case cancelled
}

/// A frame-level, bidirectional channel between two peers. The transport owns
/// framing (encode on send, incremental decode on receive) so higher layers deal
/// only in `Frame`s. This makes the `Session` unit-testable against a fake transport.
///
/// Callbacks are invoked on an unspecified queue; `Session` re-dispatches onto its
/// own serial queue.
public protocol Transport: AnyObject {
    var onFrame: ((Frame) -> Void)? { get set }
    var onState: ((TransportState) -> Void)? { get set }
    /// Reports a human-readable description of the network interface in use (e.g.
    /// "Thunderbolt (bridge0)", "Wi-Fi") once the connection is established.
    var onInterface: ((String) -> Void)? { get set }
    /// Fired once, just before `.ready`, on a cert-based TLS transport: the peer's pinned-key
    /// identity + the pairing channel binding. See `TLSPeerInfo` / docs/05.
    ///
    /// Never called by non-TLS fakes. What the `Session` does then depends on whether it is a
    /// pairing link, and the distinction is a security boundary:
    ///
    ///   • **No `pairingConfig`** — an in-process harness, never meant to authenticate anything.
    ///     The link is treated as already-trusted and the handshake proceeds. This is the path
    ///     most unit tests exercise.
    ///   • **A `pairingConfig` but no `TLSPeerInfo`** — a link that is *supposed* to authenticate
    ///     but has no verified peer identity to bind the PAKE to and nothing to pin. It **fails
    ///     closed** with `BYE(auth)`. Treating this like the case above would hand out a fully
    ///     authenticated session to an unverified peer.
    var onSecurity: ((TLSPeerInfo) -> Void)? { get set }

    func start()
    /// Encode and send one frame. `seq` is chosen by the caller (`Session`).
    func send(rawType: UInt8, flags: UInt8, seq: UInt32, payload: Data)
    func cancel()
}

public extension Transport {
    func send(type: MessageType, flags: UInt8 = 0, seq: UInt32, payload: Data) {
        send(rawType: type.rawValue, flags: flags, seq: seq, payload: payload)
    }
}
