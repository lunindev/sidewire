//! Unit tests for the pairing rate limiter with an injectable clock — mirrors the Swift
//! `PairingTests.testRateLimiter…` cases, but deterministic (no real sleeping).

use std::sync::Arc;
use std::time::Duration;

use sidewire_viewer::rate_limiter::{ManualClock, PairingRateLimiter};

#[test]
fn locks_after_threshold_then_clears_on_success() {
    let limiter = PairingRateLimiter::new(5, Duration::from_secs(60), Duration::from_secs(900));
    for _ in 0..4 {
        assert!(limiter.allow_attempt());
        limiter.record_failure();
    }
    assert!(limiter.allow_attempt(), "still allowed after 4 failures");
    limiter.record_failure(); // 5th → lockout
    assert!(!limiter.allow_attempt(), "locked after 5 failures");
    assert!(limiter.lockout_remaining() > Duration::ZERO);

    limiter.record_success();
    assert!(limiter.allow_attempt());
    assert_eq!(limiter.lockout_remaining(), Duration::ZERO);
}

#[test]
fn lockout_expires_and_doubles_on_the_clock() {
    let clock = Arc::new(ManualClock::new());
    // threshold 1 so each failure locks immediately; base 60 s, cap 900 s.
    let limiter = PairingRateLimiter::with_clock(
        1,
        Duration::from_secs(60),
        Duration::from_secs(900),
        clock.clone(),
    );

    limiter.record_failure(); // lockout #1 = 60 s
    assert!(!limiter.allow_attempt());
    // Just before expiry it is still locked.
    clock.advance(Duration::from_secs(59));
    assert!(!limiter.allow_attempt());
    // After the window elapses it clears.
    clock.advance(Duration::from_secs(2));
    assert!(limiter.allow_attempt());

    limiter.record_failure(); // lockout #2 = 120 s (doubled)
    assert!(!limiter.allow_attempt());
    clock.advance(Duration::from_secs(119));
    assert!(!limiter.allow_attempt(), "second lockout must be ~120 s");
    clock.advance(Duration::from_secs(2));
    assert!(limiter.allow_attempt());
}

#[test]
fn record_failure_never_panics_at_high_lockout_count() {
    // Regression: `Duration::mul_f64` panics on overflow, so a persistent attacker who racks up
    // many lockouts must not crash the responder. Drive 200 lockouts (threshold 1) with the real
    // 60 s base / 900 s cap; `2^199` overflows a Duration, so every window must clamp to the cap in
    // f64 and never panic. (The pre-fix code panicked once lockout_count reached ~60.)
    let clock = Arc::new(ManualClock::new());
    let limiter = PairingRateLimiter::with_clock(
        1,
        Duration::from_secs(60),
        Duration::from_secs(900),
        clock.clone(),
    );
    for _ in 0..200 {
        limiter.record_failure();
        assert!(limiter.lockout_remaining() <= Duration::from_secs(900));
        clock.advance(Duration::from_secs(901));
        assert!(limiter.allow_attempt());
    }
}

#[test]
fn lockout_is_capped() {
    let clock = Arc::new(ManualClock::new());
    // base 1 s doubling, cap 8 s.
    let limiter = PairingRateLimiter::with_clock(
        1,
        Duration::from_secs(1),
        Duration::from_secs(8),
        clock.clone(),
    );
    // Drive several lockouts; the window must never exceed the cap.
    for _ in 0..6 {
        limiter.record_failure();
        assert!(limiter.lockout_remaining() <= Duration::from_secs(8));
        // clear the window before the next failure
        clock.advance(Duration::from_secs(9));
        assert!(limiter.allow_attempt());
    }
}
