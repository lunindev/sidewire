import Foundation

/// Bounds online PIN guessing on the Display (server) side. A 6-digit PIN has only a million
/// values, so an attacker who can retry pairing freely would brute-force it quickly. This
/// throttles that: after `threshold` consecutive failed proofs the Display refuses new pairing
/// attempts for a lockout window; repeated lockouts double the window (capped); a correct PIN
/// resets everything.
///
/// In-memory only (a restart clears it — acceptable per docs/00 §D11). One instance per
/// Display; consulted by the accepting `Session` at proof time.
public final class PairingRateLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let threshold: Int
    private let baseLockout: TimeInterval
    private let cap: TimeInterval

    private var consecutiveFailures = 0
    private var lockoutCount = 0
    private var lockedUntil: Date?

    /// - Parameters:
    ///   - threshold: consecutive failures that trigger a lockout (default 5).
    ///   - baseLockout: first lockout duration in seconds (default 60); doubles each lockout.
    ///   - cap: maximum lockout duration in seconds (default 900 = 15 min).
    public init(threshold: Int = 5, baseLockout: TimeInterval = 60, cap: TimeInterval = 900) {
        self.threshold = threshold
        self.baseLockout = baseLockout
        self.cap = cap
    }

    /// True if a new pairing attempt is allowed right now. False while a lockout window is active
    /// (the caller rejects immediately with BYE("rateLimited")). Clears an expired lockout.
    public func allowAttempt() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let until = lockedUntil {
            if Date() < until { return false }
            lockedUntil = nil // window elapsed
        }
        return true
    }

    /// Seconds remaining in the current lockout, or 0 if not locked (for UI/logging).
    public func lockoutRemaining() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard let until = lockedUntil else { return 0 }
        return max(0, until.timeIntervalSinceNow)
    }

    /// Record a failed proof. On hitting the threshold, start (or escalate) a lockout window.
    public func recordFailure() {
        lock.lock(); defer { lock.unlock() }
        consecutiveFailures += 1
        guard consecutiveFailures >= threshold else { return }
        consecutiveFailures = 0
        lockoutCount += 1
        let duration = min(baseLockout * pow(2, Double(lockoutCount - 1)), cap)
        lockedUntil = Date().addingTimeInterval(duration)
        coreLog.notice("pairing rate limit: locked out for \(Int(duration))s after \(self.threshold) failures")
    }

    /// Record a successful proof — clears all failure/lockout state.
    public func recordSuccess() {
        lock.lock(); defer { lock.unlock() }
        consecutiveFailures = 0
        lockoutCount = 0
        lockedUntil = nil
    }
}
