//! Sidewire Rust Display client (Phase 8, milestone M1) — TLS 1.3 transport, trust store, rate
//! limiter, and the CPace-responder + HELLO session state machine that reaches CONFIG.
//!
//! The Rust client is always the **Display**: a TLS listener and CPace **responder**. The Mac is
//! always the Source (dialer, CPace initiator). The loopback tests also drive a Rust "Source" peer
//! (CPace initiator) so the state machine can be exercised end to end over real TLS 1.3.
//!
//! M2 added decode + a window; **M3** (this milestone) adds borderless fullscreen, input capture
//! ([`input`], winit events → HID `InputEventRecord`s), and the ≤2.5 s heartbeat/watchdog +
//! re-listen liveness contract in [`session`]/[`wire`]. M4 will add mDNS + packaging.

pub mod input;
pub mod rate_limiter;
pub mod renderer;
pub mod session;
pub mod stats;
pub mod tls;
pub mod trust_store;
pub mod window;
pub mod wire;
