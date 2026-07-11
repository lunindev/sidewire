import Foundation
import Network

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
            Task { @MainActor in self?.interfaces = ifaces }
        }
        m.start(queue: queue)
        monitor = m
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }
}
