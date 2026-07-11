import Foundation
import Network
import SidewireProtocol

/// A discovered peer (a Display advertising over Bonjour).
public struct DiscoveredPeer: Identifiable, Hashable, Sendable {
    public let id: String       // Bonjour service name (stable enough for the list)
    public let name: String
    public let endpoint: NWEndpoint

    public static func == (lhs: DiscoveredPeer, rhs: DiscoveredPeer) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Browses for Sidewire services on the local network (Source role). Keep it running
/// continuously so Phase 1 reconnection can re-resolve by service name (not a cached IP).
public final class Discovery: @unchecked Sendable {
    public var onPeersChanged: (([DiscoveredPeer]) -> Void)?

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
            if case .failed = state {
                self?.queue.asyncAfter(deadline: .now() + 2) { self?.start() }
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
                return DiscoveredPeer(id: name, name: name, endpoint: result.endpoint)
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
}
