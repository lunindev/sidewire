import Foundation

// MARK: - JSON control messages (cold path)

/// Advertised capabilities exchanged in HELLO.
public struct Capabilities: Codable, Sendable, Equatable {
    public var videoCodecs: [String]   // preference order, e.g. ["hevc", "h264"]
    public var maxWidth: Int
    public var maxHeight: Int
    public var maxFps: Int
    public var ltr: Bool
    public var audio: Bool
    public var hdr: Bool

    public init(videoCodecs: [String], maxWidth: Int, maxHeight: Int, maxFps: Int,
                ltr: Bool, audio: Bool, hdr: Bool) {
        self.videoCodecs = videoCodecs
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.maxFps = maxFps
        self.ltr = ltr
        self.audio = audio
        self.hdr = hdr
    }
}

public struct ProtocolVersion: Codable, Sendable, Equatable {
    public var major: UInt16
    public var minor: UInt16
    public init(major: UInt16, minor: UInt16) { self.major = major; self.minor = minor }
    public static let current = ProtocolVersion(major: ProtocolConstants.major,
                                                minor: ProtocolConstants.minor)
}

/// First message each peer sends after TLS is ready.
public struct Hello: Codable, Sendable, Equatable {
    public var magic: String
    public var version: ProtocolVersion
    public var role: Role
    public var deviceId: String
    public var deviceName: String
    public var sessionId: String
    public var capabilities: Capabilities

    public init(role: Role, deviceId: String, deviceName: String,
                sessionId: String, capabilities: Capabilities,
                version: ProtocolVersion = .current, magic: String = ProtocolConstants.magic) {
        self.magic = magic
        self.version = version
        self.role = role
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.sessionId = sessionId
        self.capabilities = capabilities
    }

    /// Validate a received HELLO against our own role.
    public func validate(againstLocalRole localRole: Role) -> HelloRejection? {
        if magic != ProtocolConstants.magic { return .badMagic }
        if version.major != ProtocolConstants.major { return .protocolMismatch }
        if role != localRole.opposite { return .roleConflict }
        return nil
    }
}

public enum HelloRejection: String, Sendable {
    case badMagic
    case protocolMismatch = "protocol"
    case roleConflict = "role"
}

/// The negotiated streaming configuration, computed by the source and sent to the display.
public struct Config: Codable, Sendable, Equatable {
    public var codec: String
    public var width: Int
    public var height: Int
    public var fps: Int
    public var ltr: Bool
    public var bitrateStartBps: Int
    public var bitrateMinBps: Int
    public var bitrateMaxBps: Int
    /// Whether the source should create the virtual display HiDPI (2×, logical size = pixels/2)
    /// vs standard 1× (logical size = pixels). Derived from the Display's `scaleFactor`.
    /// Optional-with-default per the protocol evolution policy: absent in old JSON ⇒ HiDPI
    /// (the pre-6.2 always-HiDPI behavior). Read it as `config.hiDPI ?? true`.
    public var hiDPI: Bool?

    public init(codec: String, width: Int, height: Int, fps: Int, ltr: Bool,
                bitrateStartBps: Int, bitrateMinBps: Int, bitrateMaxBps: Int,
                hiDPI: Bool? = true) {
        self.codec = codec
        self.width = width
        self.height = height
        self.fps = fps
        self.ltr = ltr
        self.bitrateStartBps = bitrateStartBps
        self.bitrateMinBps = bitrateMinBps
        self.bitrateMaxBps = bitrateMaxBps
        self.hiDPI = hiDPI
    }
}

/// The display's native panel description, sent right after HELLO_ACK.
public struct DisplayInfo: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var scaleFactor: Double
    public var refreshRate: Double
    public var name: String

    public init(width: Int, height: Int, scaleFactor: Double, refreshRate: Double, name: String) {
        self.width = width
        self.height = height
        self.scaleFactor = scaleFactor
        self.refreshRate = refreshRate
        self.name = name
    }
}

/// Periodic receiver → sender quality feedback (~2 Hz) driving adaptive bitrate.
public struct Feedback: Codable, Sendable, Equatable {
    public var lossPct: Double
    public var jitterMs: Double
    public var decodeQueue: Int
    public var presentedFps: Int
    public var rttMsEstimate: Int

    public init(lossPct: Double, jitterMs: Double, decodeQueue: Int,
                presentedFps: Int, rttMsEstimate: Int) {
        self.lossPct = lossPct
        self.jitterMs = jitterMs
        self.decodeQueue = decodeQueue
        self.presentedFps = presentedFps
        self.rttMsEstimate = rttMsEstimate
    }
}

/// Reason carried by PAUSE / BYE.
public struct ReasonMessage: Codable, Sendable, Equatable {
    public var reason: String
    public init(reason: String) { self.reason = reason }
}

// MARK: - JSON codec helper

public enum JSONWire {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    public static func encode<T: Encodable>(_ value: T) -> Data {
        (try? encoder.encode(value)) ?? Data()
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? decoder.decode(type, from: data)
    }
}
