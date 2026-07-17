import Foundation
import OSLog

/// Severity for the diagnostics ring buffer (mirrors the os.Logger levels we use).
enum LogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case notice = "NOTE"
    case error = "ERROR"
}

/// Log categories — one per subsystem area. Mirrors the os.Logger category names.
enum LogCategory: String {
    case source, display, net, media, app
}

/// Bounded in-memory ring buffer that mirrors high-value log lines for "Export Diagnostics".
/// Thread-safe: appended from the main actor (controller state transitions) and occasionally
/// background queues, snapshotted on the main actor for export. `.debug` lines are only
/// retained when verbose logging is enabled (gated in `Log.event`).
final class LogBuffer: @unchecked Sendable {
    static let shared = LogBuffer()

    private let capacity = 2000
    private var lines: [String] = []
    private let lock = NSLock()
    private var verboseEnabled: Bool

    static let verboseDefaultsKey = "sidewire.verboseLogging"

    private init() {
        verboseEnabled = UserDefaults.standard.bool(forKey: Self.verboseDefaultsKey)
        lines.reserveCapacity(capacity)
    }

    var verbose: Bool {
        lock.lock(); defer { lock.unlock() }
        return verboseEnabled
    }

    func setVerbose(_ on: Bool) {
        lock.lock(); verboseEnabled = on; lock.unlock()
        UserDefaults.standard.set(on, forKey: Self.verboseDefaultsKey)
    }

    func append(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        let ts = LogBuffer.formatter.string(from: Date())
        let line = "\(ts) [\(category.rawValue)] \(level.rawValue): \(message)"
        lock.lock()
        lines.append(line)
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        lock.unlock()
    }

    /// Copy of the retained lines, oldest first.
    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

/// Lightweight logging facade. Categories are bare os.Logger wrappers for the hot path;
/// `Log.event(...)` additionally tees a line into an in-memory ring buffer that
/// "Export Diagnostics" writes out (D6). Subsystem matches the app's bundle id so one
/// predicate catches app + core logs:
///   log stream --predicate 'subsystem == "com.kinocoder.sidewire"'
enum Log {
    private static let subsystem = "com.kinocoder.sidewire"
    static let source = Logger(subsystem: subsystem, category: "source")
    static let display = Logger(subsystem: subsystem, category: "display")
    static let net = Logger(subsystem: subsystem, category: "net")
    static let media = Logger(subsystem: subsystem, category: "media")
    static let app = Logger(subsystem: subsystem, category: "app")

    static let buffer = LogBuffer.shared

    /// Tee a line to both the unified log and the diagnostics ring buffer. Use at high-value
    /// lifecycle call sites (connection state, permissions, virtual-display lifecycle) so an
    /// exported diagnostic reflects the session without rewiring every os_log call. `.debug`
    /// lines reach the buffer only when verbose logging is enabled.
    static func event(_ category: LogCategory, _ message: String, level: LogLevel = .info) {
        let log = logger(for: category)
        switch level {
        case .debug: log.debug("\(message, privacy: .public)")
        case .info: log.info("\(message, privacy: .public)")
        case .notice: log.notice("\(message, privacy: .public)")
        case .error: log.error("\(message, privacy: .public)")
        }
        if level == .debug && !buffer.verbose { return }
        buffer.append(level, category, message)
    }

    private static func logger(for category: LogCategory) -> Logger {
        switch category {
        case .source: return source
        case .display: return display
        case .net: return net
        case .media: return media
        case .app: return app
        }
    }
}
