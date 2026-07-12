//! Bounds online PIN guessing on the Display (server) side. Mirrors `PairingRateLimiter.swift`.
//! After `threshold` consecutive failed pairings, a lockout window (base, doubling, capped) refuses
//! new attempts; a success resets everything. In-memory only (a relaunch clears it).
//!
//! The clock is injectable so a lockout test is deterministic and does not sleep the base window.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// A monotonic clock source. The real one is [`SystemClock`]; tests use [`ManualClock`].
pub trait Clock: Send + Sync {
    fn now(&self) -> Instant;
}

/// The real, monotonic system clock.
pub struct SystemClock;
impl Clock for SystemClock {
    fn now(&self) -> Instant {
        Instant::now()
    }
}

/// A test clock that only advances when told to.
pub struct ManualClock {
    t: Mutex<Instant>,
}

impl Default for ManualClock {
    fn default() -> Self {
        Self {
            t: Mutex::new(Instant::now()),
        }
    }
}

impl ManualClock {
    pub fn new() -> Self {
        Self::default()
    }

    /// Advance the virtual clock by `d`.
    pub fn advance(&self, d: Duration) {
        let mut t = self.t.lock().unwrap();
        *t += d;
    }
}

impl Clock for ManualClock {
    fn now(&self) -> Instant {
        *self.t.lock().unwrap()
    }
}

struct State {
    consecutive_failures: usize,
    lockout_count: u32,
    locked_until: Option<Instant>,
}

/// Rate-limits online PIN guessing. Consulted by the Display's `Session` at pairing time.
pub struct PairingRateLimiter {
    threshold: usize,
    base_lockout: Duration,
    cap: Duration,
    clock: Arc<dyn Clock>,
    state: Mutex<State>,
}

impl PairingRateLimiter {
    /// Default parameters (threshold 5, base lockout 60 s doubling, cap 900 s = 15 min) on the
    /// real system clock.
    pub fn new(threshold: usize, base_lockout: Duration, cap: Duration) -> Self {
        Self::with_clock(threshold, base_lockout, cap, Arc::new(SystemClock))
    }

    /// Same, with an injectable clock (deterministic tests).
    pub fn with_clock(
        threshold: usize,
        base_lockout: Duration,
        cap: Duration,
        clock: Arc<dyn Clock>,
    ) -> Self {
        Self {
            threshold,
            base_lockout,
            cap,
            clock,
            state: Mutex::new(State {
                consecutive_failures: 0,
                lockout_count: 0,
                locked_until: None,
            }),
        }
    }

    /// The default Sidewire configuration: 5 failures → 60 s lockout doubling, capped at 15 min.
    pub fn default_config() -> Self {
        Self::new(5, Duration::from_secs(60), Duration::from_secs(900))
    }

    /// True if a new pairing attempt is allowed right now. False while a lockout window is active
    /// (the caller rejects immediately with `BYE("rateLimited")`). Clears an expired lockout.
    pub fn allow_attempt(&self) -> bool {
        let mut s = self.state.lock().unwrap();
        if let Some(until) = s.locked_until {
            if self.clock.now() < until {
                return false;
            }
            s.locked_until = None; // window elapsed
        }
        true
    }

    /// Seconds remaining in the current lockout, or zero if not locked (for UI/logging).
    pub fn lockout_remaining(&self) -> Duration {
        let s = self.state.lock().unwrap();
        match s.locked_until {
            Some(until) => until.saturating_duration_since(self.clock.now()),
            None => Duration::ZERO,
        }
    }

    /// Consecutive failures recorded since the last success (for diagnostics/tests).
    pub fn consecutive_failures(&self) -> usize {
        self.state.lock().unwrap().consecutive_failures
    }

    /// Record a failed proof. On hitting the threshold, start (or escalate) a lockout window.
    pub fn record_failure(&self) {
        let mut s = self.state.lock().unwrap();
        s.consecutive_failures += 1;
        if s.consecutive_failures < self.threshold {
            return;
        }
        s.consecutive_failures = 0;
        s.lockout_count += 1;
        // Compute `min(base·2^(n-1), cap)` in f64 and clamp BEFORE building the Duration — exactly
        // as Swift's `min(baseLockout * pow(2, n-1), cap)` does in Double. `Duration::mul_f64`
        // panics on overflow / non-finite input, so a persistent attacker who accumulates dozens of
        // lockouts could otherwise crash the responder thread once `2^(n-1)` overflows a Duration.
        // Clamping first keeps the argument finite and ≤ cap (`min(inf, cap_secs) == cap_secs`), so
        // `try_from_secs_f64` cannot fail; the `unwrap_or(cap)` is belt-and-suspenders.
        let factor = 2f64.powi((s.lockout_count - 1) as i32);
        let secs = (self.base_lockout.as_secs_f64() * factor).min(self.cap.as_secs_f64());
        let duration = Duration::try_from_secs_f64(secs).unwrap_or(self.cap);
        s.locked_until = Some(self.clock.now() + duration);
    }

    /// Record a successful proof — clears all failure/lockout state.
    pub fn record_success(&self) {
        let mut s = self.state.lock().unwrap();
        s.consecutive_failures = 0;
        s.lockout_count = 0;
        s.locked_until = None;
    }
}
