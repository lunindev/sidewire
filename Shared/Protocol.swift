import Foundation
import Network

let kDefaultPort: UInt16 = 5005

struct AvailableInterface: Identifiable, Hashable {
    let name: String
    let type: NWInterface.InterfaceType
    let nwInterface: NWInterface

    var id: String { name }

    var label: String {
        switch type {
        case .wifi: return "WiFi (\(name))"
        case .wiredEthernet:
            if name.hasPrefix("bridge") { return "Thunderbolt (\(name))" }
            return "Ethernet (\(name))"
        case .loopback: return "Loopback (\(name))"
        default: return name
        }
    }

    static func == (lhs: AvailableInterface, rhs: AvailableInterface) -> Bool { lhs.name == rhs.name }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

final class InterfaceMonitor: ObservableObject {
    @Published var availableInterfaces: [AvailableInterface] = []
    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "com.macdisplay.ifmonitor")

    func start() {
        monitor = NWPathMonitor()
        monitor?.pathUpdateHandler = { [weak self] path in
            let interfaces = path.availableInterfaces.compactMap { iface -> AvailableInterface? in
                switch iface.type {
                case .wifi, .wiredEthernet:
                    return AvailableInterface(name: iface.name, type: iface.type, nwInterface: iface)
                default:
                    return nil
                }
            }
            DispatchQueue.main.async {
                self?.availableInterfaces = interfaces
            }
        }
        monitor?.start(queue: queue)
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }
}

func tcpParameters(interface: NWInterface?) -> NWParameters {
    let params = NWParameters.tcp
    if let interface {
        params.requiredInterface = interface
    }
    return params
}

let kPacketHeaderSize: Int = 13
let kBonjourServiceType = "_macdisplay._tcp"

enum PacketType: UInt8 {
    case videoFrame = 1
    case keyFrame = 2
    case text = 3
    case displayInfo = 4
    case inputEvent = 5
}

enum InputEventType: UInt8, Codable {
    case mouseMove = 1
    case mouseDown = 2
    case mouseUp = 3
    case rightMouseDown = 4
    case rightMouseUp = 5
    case scrollWheel = 6
    case keyDown = 7
    case keyUp = 8
    case flagsChanged = 9
    case mouseDragged = 10
    case rightMouseDragged = 11
}

struct InputEvent: Codable {
    var type: InputEventType
    var x: Double
    var y: Double
    var deltaX: Double
    var deltaY: Double
    var keyCode: UInt16
    var modifierFlags: UInt
    var clickCount: Int
    var buttonNumber: Int

    var encoded: Data? { try? JSONEncoder().encode(self) }
    static func decode(from data: Data) -> InputEvent? { try? JSONDecoder().decode(InputEvent.self, from: data) }
}

struct DisplayInfo: Codable {
    var width: Int
    var height: Int
    var refreshRate: Double
    var scaleFactor: Double
    var name: String

    var encoded: Data? { try? JSONEncoder().encode(self) }
    static func decode(from data: Data) -> DisplayInfo? { try? JSONDecoder().decode(DisplayInfo.self, from: data) }
}

struct PacketHeader {
    var dataSize: UInt32
    var timestampMs: UInt64
    var type: PacketType

    var encodedData: Data {
        var data = Data(capacity: kPacketHeaderSize)
        var size = dataSize.bigEndian
        var ts = timestampMs.bigEndian
        data.append(Data(bytes: &size, count: 4))
        data.append(Data(bytes: &ts, count: 8))
        data.append(type.rawValue)
        return data
    }

    static func decode(from data: Data) -> PacketHeader? {
        guard data.count >= kPacketHeaderSize else { return nil }
        var size: UInt32 = 0
        var ts: UInt64 = 0
        _ = withUnsafeMutableBytes(of: &size) { data.copyBytes(to: $0, from: 0..<4) }
        _ = withUnsafeMutableBytes(of: &ts) { data.copyBytes(to: $0, from: 4..<12) }
        let rawType = data[12]
        let type = PacketType(rawValue: rawType) ?? .videoFrame
        return PacketHeader(dataSize: size.bigEndian, timestampMs: ts.bigEndian, type: type)
    }
}

func currentTimestampMs() -> UInt64 {
    UInt64(Date().timeIntervalSince1970 * 1000)
}
