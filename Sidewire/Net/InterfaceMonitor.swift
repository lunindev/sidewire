import Foundation
import Network
import Darwin

/// A selectable network interface (Wi-Fi / Thunderbolt bridge / Ethernet).
struct AvailableInterface: Identifiable, Hashable {
    let name: String
    let type: NWInterface.InterfaceType
    let nwInterface: NWInterface
    var id: String { name }

    var label: String {
        switch type {
        case .wifi: return "Wi-Fi"
        case .wiredEthernet:
            return name.hasPrefix("bridge") ? "Thunderbolt (\(name))" : "Ethernet (\(name))"
        default: return name
        }
    }

    static func == (lhs: AvailableInterface, rhs: AvailableInterface) -> Bool { lhs.name == rhs.name }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

/// Publishes the available Wi-Fi/Ethernet/Thunderbolt interfaces so the user can pin the
/// connection to one (e.g. force the direct Thunderbolt cable instead of Wi-Fi).
@MainActor
final class InterfaceMonitor: ObservableObject {
    @Published var interfaces: [AvailableInterface] = []

    /// Fired on the main actor whenever the interface list changes — the Source uses it to
    /// validate a persisted interface selection that may have gone away.
    var onInterfacesChanged: (() -> Void)?
    /// Fired on the main actor when this Mac's Thunderbolt-bridge IP appears, disappears, or
    /// changes — the Source refreshes its cable hint and the Display re-advertises its TXT.
    var onThunderboltIPChanged: ((String?) -> Void)?
    private var lastThunderboltIP: String?

    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "com.kinocoder.sidewire.ifmonitor")

    func start() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let ifaces = path.availableInterfaces.compactMap { iface -> AvailableInterface? in
                switch iface.type {
                case .wifi, .wiredEthernet:
                    return AvailableInterface(name: iface.name, type: iface.type, nwInterface: iface)
                default:
                    return nil
                }
            }
            // The Thunderbolt bridge is link-local-only and read directly from the BSD list;
            // a path change is our best signal that a cable was plugged/unplugged.
            let tb = InterfaceMonitor.localThunderboltIP()
            Task { @MainActor in
                guard let self else { return }
                self.interfaces = ifaces
                self.onInterfacesChanged?()
                if tb != self.lastThunderboltIP {
                    self.lastThunderboltIP = tb
                    self.onThunderboltIPChanged?(tb)
                }
            }
        }
        m.start(queue: queue)
        monitor = m
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }

    /// This Mac's own Thunderbolt Bridge IPv4 address (e.g. "169.254.36.98"), if the
    /// cable is connected. NWPathMonitor omits this link-local-only interface, so we read
    /// it directly from the BSD interface list. Used to hint the Connect-by-IP flow.
    /// `nonisolated`: a pure BSD read touching no actor state, so the path-update handler can
    /// call it off the main actor.
    nonisolated static func localThunderboltIP() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let name = String(cString: cur.pointee.ifa_name)
            guard name.hasPrefix("bridge"), let sa = cur.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET),
                  (Int32(cur.pointee.ifa_flags) & IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                // The Thunderbolt Bridge self-assigns a 169.254.x.x link-local address;
                // this filter avoids picking up a VM/Parallels bridge (10.x etc.).
                if ip.hasPrefix("169.254.") { return ip }
            }
        }
        return nil
    }
}
