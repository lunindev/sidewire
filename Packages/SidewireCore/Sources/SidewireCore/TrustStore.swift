import Foundation

/// A peer this device has paired with. Persisted in the trust store keyed by `deviceId`.
public struct TrustedPeer: Codable, Sendable, Equatable {
    /// The peer's self-authenticating device id (= first 16 bytes of `spkiHash`, hex).
    public let deviceId: String
    /// SHA-256 of the peer's DER SubjectPublicKeyInfo (32 bytes), lowercase hex — the pin.
    public let spkiHash: String
    /// Human label (the peer's `deviceName` at pairing time). Best-effort; may be empty until
    /// the peer's HELLO is seen.
    public var name: String
    /// When this peer was first pinned (Unix epoch seconds).
    public let pairedAt: Double

    public init(deviceId: String, spkiHash: String, name: String, pairedAt: Double = Date().timeIntervalSince1970) {
        self.deviceId = deviceId
        self.spkiHash = spkiHash
        self.name = name
        self.pairedAt = pairedAt
    }
}

/// The set of Macs this device trusts. Backed by the Keychain in the app; tests can substitute
/// an in-memory fake. Implementations must be safe to call from any thread.
public protocol TrustStoring: AnyObject, Sendable {
    /// All currently-pinned peers (for the "Paired Macs" settings list).
    func peers() -> [TrustedPeer]
    /// The pin for a peer, or nil if not paired.
    func pinned(for deviceId: String) -> TrustedPeer?
    /// Pin (or update) a peer.
    func pin(_ peer: TrustedPeer)
    /// Revoke trust in a peer ("Forget this Mac"). The next connection re-pairs.
    func forget(_ deviceId: String)
}

public extension TrustStoring {
    /// Convenience: is this peer currently trusted?
    func isPaired(_ deviceId: String) -> Bool { pinned(for: deviceId) != nil }
}

// MARK: - In-memory fake (tests)

/// A non-persistent trust store for tests (and a fallback if the Keychain is unavailable).
public final class InMemoryTrustStore: TrustStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: TrustedPeer] = [:]

    public init() {}

    public func peers() -> [TrustedPeer] {
        lock.lock(); defer { lock.unlock() }
        return Array(store.values).sorted { $0.pairedAt < $1.pairedAt }
    }
    public func pinned(for deviceId: String) -> TrustedPeer? {
        lock.lock(); defer { lock.unlock() }
        return store[deviceId]
    }
    public func pin(_ peer: TrustedPeer) {
        lock.lock(); defer { lock.unlock() }
        store[peer.deviceId] = peer
    }
    public func forget(_ deviceId: String) {
        lock.lock(); defer { lock.unlock() }
        store[deviceId] = nil
    }
}

// MARK: - Keychain-backed (app)

/// Keychain-backed trust store: one `kSecClassGenericPassword` item per peer, service
/// `com.kinocoder.sidewire.trust`, account = peer `deviceId`, value = JSON `TrustedPeer`.
/// An in-memory cache fronts the Keychain so hot-path lookups (per connection) don't hit
/// `SecItem` every time; writes update both.
public final class KeychainTrustStore: TrustStoring, @unchecked Sendable {
    public static let shared = KeychainTrustStore()

    public static let service = "com.kinocoder.sidewire.trust"

    private let lock = NSLock()
    private var cache: [String: TrustedPeer]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(service: String = KeychainTrustStore.service) {
        self.serviceName = service
        self.cache = [:]
        reloadCache()
    }

    private let serviceName: String

    public func peers() -> [TrustedPeer] {
        lock.lock(); defer { lock.unlock() }
        return Array(cache.values).sorted { $0.pairedAt < $1.pairedAt }
    }

    public func pinned(for deviceId: String) -> TrustedPeer? {
        lock.lock(); defer { lock.unlock() }
        return cache[deviceId]
    }

    public func pin(_ peer: TrustedPeer) {
        lock.lock(); defer { lock.unlock() }
        cache[peer.deviceId] = peer
        guard let data = try? encoder.encode(peer) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: peer.deviceId,
        ]
        // Upsert: try update first, then add.
        let update: [String: Any] = [kSecValueData as String: data]
        let updStatus = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if updStatus == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus != errSecSuccess {
                coreLog.error("trust store: pin add failed for \(peer.deviceId, privacy: .public): \(addStatus)")
            }
        } else if updStatus != errSecSuccess {
            coreLog.error("trust store: pin update failed for \(peer.deviceId, privacy: .public): \(updStatus)")
        }
    }

    public func forget(_ deviceId: String) {
        lock.lock(); defer { lock.unlock() }
        cache[deviceId] = nil
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: deviceId,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Load every pinned peer from the Keychain into the cache (called once at init).
    ///
    /// Done in two steps because the file-based (login) Keychain rejects a `MatchLimitAll` query
    /// that also asks for `kSecValueData` (errSecParam): first enumerate the accounts (device
    /// ids) with attributes only, then fetch each item's JSON individually. Trust stores are
    /// small (a handful of paired Macs), so the extra `SecItem` calls are negligible.
    private func reloadCache() {
        let listQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(listQuery as CFDictionary, &out)
        guard status == errSecSuccess, let items = out as? [[String: Any]] else {
            if status != errSecItemNotFound {
                coreLog.error("trust store: reload failed: \(status)")
            }
            return
        }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = loadData(account: account),
                  let peer = try? decoder.decode(TrustedPeer.self, from: data) else { continue }
            cache[peer.deviceId] = peer
        }
    }

    /// Fetch one item's stored JSON by account (device id).
    private func loadData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
}
