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

/// A reachable IPv4 address on this Mac, with a human label ("Wi-Fi", "Ethernet", "Thunderbolt").
/// Shown on the Display's waiting screen so the other Mac's Connect-by-IP field can be typed
/// without digging through System Settings.
struct LocalAddress: Identifiable, Hashable {
    let label: String
    let ip: String
    /// Sort/grouping priority: Thunderbolt first (link-local, impossible to guess and the cable
    /// path this app favors), then Wi-Fi, then Ethernet, then anything else.
    let priority: Int
    var id: String { "\(label)-\(ip)" }
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
    /// Fired on the main actor whenever this Mac's reachable IPv4 addresses change — the Display
    /// shows them on its waiting screen so the other Mac's Connect-by-IP field is easy to type.
    var onAddressesChanged: (([LocalAddress]) -> Void)?

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
            let addrs = InterfaceMonitor.localAddresses(labeling: ifaces)
            Task { @MainActor in
                guard let self else { return }
                self.interfaces = ifaces
                self.onInterfacesChanged?()
                if tb != self.lastThunderboltIP {
                    self.lastThunderboltIP = tb
                    self.onThunderboltIPChanged?(tb)
                }
                self.onAddressesChanged?(addrs)
            }
        }
        m.start(queue: queue)
        monitor = m
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }

    /// This Mac's reachable IPv4 addresses, each with a friendly label, sorted Thunderbolt →
    /// Wi-Fi → Ethernet → other. `labeling` is the NWPathMonitor interface list (name→type), used
    /// to name Wi-Fi vs Ethernet reliably; the Thunderbolt bridge (which NWPathMonitor omits) is
    /// recovered from the raw BSD list. `nonisolated`: a pure BSD read, safe off the main actor.
    nonisolated static func localAddresses(labeling known: [AvailableInterface]) -> [LocalAddress] {
        let typeByName: [String: NWInterface.InterfaceType] =
            Dictionary(known.map { ($0.name, $0.type) }, uniquingKeysWith: { a, _ in a })

        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }

        var out: [LocalAddress] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = head
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET),
                  (Int32(cur.pointee.ifa_flags) & IFF_UP) != 0,
                  (Int32(cur.pointee.ifa_flags) & IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            // Apple virtual/internal interfaces carry addresses we never want to advertise for a
            // manual connect (AirDrop mesh, VPN tunnels, cellular-assist, hotspot bridge, etc.).
            if ["utun", "awdl", "llw", "anpi", "ap", "gif", "stf", "XHC"]
                .contains(where: { name.hasPrefix($0) }) { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip == "127.0.0.1" { continue }

            let label: String, priority: Int
            if name.hasPrefix("bridge") {
                // Only the Thunderbolt Bridge (self-assigned 169.254.x.x link-local); skip a
                // VM/Parallels bridge (10.x etc.), which isn't reachable from the other Mac.
                guard ip.hasPrefix("169.254.") else { continue }
                (label, priority) = ("Thunderbolt", 0)
            } else if typeByName[name] == .wifi {
                (label, priority) = ("Wi-Fi", 1)
            } else if typeByName[name] == .wiredEthernet || name.hasPrefix("en") {
                (label, priority) = ("Ethernet", 2)
            } else {
                (label, priority) = (name, 3)
            }
            out.append(LocalAddress(label: label, ip: ip, priority: priority))
        }
        // Stable, de-duplicated, priority-ordered.
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
                  .sorted { $0.priority != $1.priority ? $0.priority < $1.priority : $0.ip < $1.ip }
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
