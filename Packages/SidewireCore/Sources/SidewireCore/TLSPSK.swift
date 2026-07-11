import Foundation
import Network
import Security

/// A pre-shared key credential for TLS-PSK: the symmetric key + an identity the server
/// uses to look it up. See docs/05 — the key is derived from the pairing PIN on first
/// contact, then a stored strong key thereafter.
public struct PSKCredential: Sendable, Equatable {
    public let key: Data
    public let identity: Data
    public init(key: Data, identity: Data) {
        self.key = key
        self.identity = identity
    }
    public init(key: Data, identity: String) {
        self.key = key
        self.identity = Data(identity.utf8)
    }
}

enum TLSPSK {
    /// Build NWProtocolTLS options that authenticate + encrypt the connection with a
    /// pre-shared key (no certificate/CA needed for a peer-to-peer LAN link).
    static func options(_ psk: PSKCredential) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions

        let keyDD = psk.key.withUnsafeBytes { DispatchData(bytes: $0) }
        let idDD = psk.identity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(sec, keyDD as __DispatchData, idDD as __DispatchData)

        // A PSK ciphersuite is required for the PSK key exchange (TLS 1.2).
        sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
        return tls
    }
}
