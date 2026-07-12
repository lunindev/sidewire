import Foundation
import Network
import SidewireProtocol

/// A discovered peer (a Display advertising over Bonjour).
public struct DiscoveredPeer: Identifiable, Hashable, Sendable {
    public let id: String       // Bonjour service name (stable enough for the list)
    public let name: String
    public let endpoint: NWEndpoint
    /// The peer's Thunderbolt link-local IP if it advertised one (TXT "tb"), so the Source
    /// can offer a one-click connect that forces the cable instead of Wi-Fi.
    public let thunderboltIP: String?

    public static func == (lhs: DiscoveredPeer, rhs: DiscoveredPeer) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Browses for Sidewire services on the local network (Source role). Keep it running
/// continuously so Phase 1 reconnection can re-resolve by service name (not a cached IP).
public final class Discovery: @unchecked Sendable {
    public var onPeersChanged: (([DiscoveredPeer]) -> Void)?
    /// Fires `true` when the browser can't make progress (`.waiting`/`.failed` — the shape a
    /// denied Local Network permission takes on) and `false` once it's `.ready`. Best-effort:
    /// the caller debounces before showing a "check Local Network permission" hint, since a
    /// brief `.waiting` at startup is normal. Invoked on the discovery queue.
    public var onWaiting: ((Bool) -> Void)?

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "sidewire.discovery")

    public init() {}

    public func start() {
        browser?.cancel()
        let params = NWParameters()
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: ProtocolConstants.bonjourServiceType,
                                                      domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)

        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onWaiting?(false)
            case .waiting:
                // Commonly a denied Local Network permission (Bonjour can't resolve), but also a
                // transient no-network state — the caller debounces before surfacing anything.
                self?.onWaiting?(true)
            case .failed:
                self?.onWaiting?(true)
                self?.queue.asyncAfter(deadline: .now() + 2) { self?.start() }
            default:
                break
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            // Dedupe by service name: the same Display can be discovered over multiple
            // interfaces (Wi-Fi + AWDL), which would otherwise produce duplicate rows
            // with the same Identifiable id — a SwiftUI hazard.
            var seen = Set<String>()
            let peers = results.compactMap { result -> DiscoveredPeer? in
                guard case let .service(name, _, _, _) = result.endpoint,
                      seen.insert(name).inserted else { return nil }
                return DiscoveredPeer(id: name, name: name, endpoint: result.endpoint,
                                      thunderboltIP: Self.thunderboltIP(from: result.metadata))
            }
            self?.onPeersChanged?(peers)
        }

        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Pull the advertised Thunderbolt IP (TXT key "tb") out of a browse result's metadata.
    private static func thunderboltIP(from metadata: NWBrowser.Result.Metadata) -> String? {
        guard case let .bonjour(txt) = metadata,
              case let .string(value) = txt.getEntry(for: "tb"),
              !value.isEmpty else { return nil }
        return value
    }
}
