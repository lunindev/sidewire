//! Sidewire Rust Display client (Phase 8, milestone M1) — TLS 1.3 transport, trust store, rate
//! limiter, and the CPace-responder + HELLO session state machine that reaches CONFIG.
//!
//! The Rust client is always the **Display**: a TLS listener and CPace **responder**. The Mac is
//! always the Source (dialer, CPace initiator). The loopback tests also drive a Rust "Source" peer
//! (CPace initiator) so the state machine can be exercised end to end over real TLS 1.3.
//!
//! Later milestones add decode + a window (M2), fullscreen + input capture (M3), and mDNS +
//! packaging (M4).

pub mod rate_limiter;
pub mod renderer;
pub mod session;
pub mod stats;
pub mod tls;
pub mod trust_store;
pub mod window;
pub mod wire;
