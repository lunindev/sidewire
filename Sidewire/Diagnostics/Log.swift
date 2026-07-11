import Foundation
import OSLog

/// Lightweight logging facade. Phase 4 adds the ring buffer + "Export diagnostics".
/// Subsystem matches the app's bundle id so one predicate catches app + core logs:
///   log stream --predicate 'subsystem == "com.kinocoder.sidewire"'
enum Log {
    private static let subsystem = "com.kinocoder.sidewire"
    static let source = Logger(subsystem: subsystem, category: "source")
    static let display = Logger(subsystem: subsystem, category: "display")
    static let net = Logger(subsystem: subsystem, category: "net")
    static let media = Logger(subsystem: subsystem, category: "media")
}
