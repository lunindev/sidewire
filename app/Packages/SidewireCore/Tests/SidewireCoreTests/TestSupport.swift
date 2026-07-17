import Foundation
import XCTest
@testable import SidewireCore
import SidewireProtocol

// MARK: - Throwaway identities

/// Tracks throwaway `LocalIdentity` instances created during a test so their Keychain items can
/// be removed in `tearDown`. Each identity is a fresh P-256 key + self-signed cert with a unique
/// tag, so tests never collide with each other or with the app's real identity.
final class IdentityBag {
    private var identities: [LocalIdentity] = []

    func make() throws -> LocalIdentity {
        let id = try LocalIdentity.ephemeral()
        identities.append(id)
        return id
    }

    func destroyAll() {
        for id in identities { id.destroy() }
        identities.removeAll()
    }
}

func testCaps(_ codecs: [String] = ["hevc"]) -> Capabilities {
    Capabilities(videoCodecs: codecs, maxWidth: 3840, maxHeight: 2160, maxFps: 60,
                 ltr: false, audio: false, hdr: false)
}

func testHello(role: Role, name: String) -> Hello {
    Hello(role: role, deviceId: name, deviceName: name, sessionId: "s", capabilities: testCaps())
}

/// A `TrustedPeer` describing `identity`, as the *other* side would pin it.
func pin(for identity: LocalIdentity, name: String) -> TrustedPeer {
    TrustedPeer(deviceId: identity.deviceId, spkiHash: identity.spkiHash.hexString, name: name)
}

// MARK: - Frame-tapping transport decorator

/// Wraps any `Transport`, forwarding every callback and call, while recording the message types
/// sent and received. Lets a test assert e.g. that a paired reconnect exchanges **no** pairing
/// messages on the wire.
final class TapTransport: Transport, @unchecked Sendable {
    private let inner: Transport
    private let lock = NSLock()
    private var sent: [UInt8] = []
    private var received: [UInt8] = []

    var onFrame: ((Frame) -> Void)?
    var onState: ((TransportState) -> Void)?
    var onInterface: ((String) -> Void)?
    var onSecurity: ((TLSPeerInfo) -> Void)?

    init(_ inner: Transport) {
        self.inner = inner
        inner.onFrame = { [weak self] f in
            guard let self else { return }
            self.lock.lock(); self.received.append(f.rawType); self.lock.unlock()
            self.onFrame?(f)
        }
        inner.onState = { [weak self] s in self?.onState?(s) }
        inner.onInterface = { [weak self] i in self?.onInterface?(i) }
        inner.onSecurity = { [weak self] x in self?.onSecurity?(x) }
    }

    func start() { inner.start() }
    func cancel() { inner.cancel() }

    func send(rawType: UInt8, flags: UInt8, seq: UInt32, payload: Data) {
        lock.lock(); sent.append(rawType); lock.unlock()
        inner.send(rawType: rawType, flags: flags, seq: seq, payload: payload)
    }

    func sentCount(of type: MessageType) -> Int {
        lock.lock(); defer { lock.unlock() }
        return sent.filter { $0 == type.rawValue }.count
    }
    func receivedCount(of type: MessageType) -> Int {
        lock.lock(); defer { lock.unlock() }
        return received.filter { $0 == type.rawValue }.count
    }
}

/// A `@unchecked Sendable` box to hold a session across the accept closure boundary.
final class SessionBox: @unchecked Sendable {
    var session: Session?
    var tap: TapTransport?
}

/// Keeps accepted display `Session`s alive for the duration of a test (nothing else retains a
/// session created inside a listener's `onConnection`; without this it would deallocate before
/// it could process the pairing proof). Thread-safe (appended from the listener queue).
final class SessionRetainer: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [Session] = []
    func keep(_ s: Session) { lock.lock(); sessions.append(s); lock.unlock() }
}
