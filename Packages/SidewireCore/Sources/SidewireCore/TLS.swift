import Foundation
import Network
import Security

/// The security context of an established cert-based TLS 1.3 connection, handed up to the
/// `Session` so it can run (or skip) the PIN proof and pin/verify the peer. See docs/05.
public struct TLSPeerInfo: Sendable {
    /// The peer's self-authenticating device id (`first16(peerSPKI)` hex), derived from the
    /// presented leaf certificate — NOT from anything the peer self-declares.
    public let peerDeviceId: String
    /// SHA-256 of the peer's DER SubjectPublicKeyInfo (32 bytes).
    public let peerSPKIHash: Data
    /// SHA-256 of our own SPKI (32 bytes).
    public let ownSPKIHash: Data
    /// `SHA256(clientSPKI ‖ serverSPKI)` — the pairing channel binding (32 bytes).
    public let channelBinding: Data
    /// True on the Display (listener/server) side, false on the Source (dialer/client) side.
    public let isServer: Bool

    public init(peerDeviceId: String, peerSPKIHash: Data, ownSPKIHash: Data,
                channelBinding: Data, isServer: Bool) {
        self.peerDeviceId = peerDeviceId
        self.peerSPKIHash = peerSPKIHash
        self.ownSPKIHash = ownSPKIHash
        self.channelBinding = channelBinding
        self.isServer = isServer
    }
}

/// Builds Network.framework TLS options for Sidewire's peer-to-peer link: **TLS 1.3 only**,
/// this device's certificate presented, mutual authentication, and a custom verify block.
///
/// The verify block **accepts any presented certificate** (`complete(true)`): there is no CA and
/// no hostname to validate against — trust is established at the app layer by the pinned public
/// key (checked against the trust store after the handshake) plus the PIN proof. Without this
/// block Network.framework would run default trust evaluation and reject the self-signed cert.
///
/// Peer-identity capture and public-key pinning ("keyChanged") are done **after** `.ready` in
/// `TCPTransport`, by reading the peer leaf certificate from the connection's TLS metadata
/// (`sec_protocol_metadata_access_peer_certificate_chain`). That works uniformly on both the
/// dialed and the accepted side, whereas the listener's verify block is shared across all
/// accepted connections and cannot capture into a specific accepted transport.
enum TLS {
    /// A dedicated queue for verify callbacks (they must not block the connection's queue).
    private static let verifyQueue = DispatchQueue(label: "sidewire.tls.verify")

    static func options(identity: LocalIdentity) -> NWProtocolTLS.Options? {
        guard let secIdentity = identity.makeSecIdentityT() else { return nil }
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_local_identity(sec, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv13)
        // Require the peer to present a certificate too (mutual auth) so the Display can pin the
        // Source's key and the channel binding covers both leaves.
        sec_protocol_options_set_peer_authentication_required(sec, true)
        sec_protocol_options_set_verify_block(sec, { _, _, complete in
            complete(true) // accept any cert; the app layer (pin + PIN proof) is the real gate
        }, verifyQueue)
        return tls
    }

    /// The peer's leaf-certificate SPKI hash, read from a ready connection's TLS metadata.
    /// Returns nil on a non-TLS connection or if no peer certificate was presented.
    static func peerLeafSPKIHash(of connection: NWConnection) -> Data? {
        guard let md = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return nil
        }
        var leaf: SecCertificate?
        sec_protocol_metadata_access_peer_certificate_chain(md.securityProtocolMetadata) { certRef in
            if leaf == nil { leaf = sec_certificate_copy_ref(certRef).takeRetainedValue() }
        }
        guard let leaf else { return nil }
        return LocalIdentity.spkiHash(fromLeaf: leaf)
    }
}
