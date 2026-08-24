# Sidewire — design specification

This directory is the design source of truth: what the protocol is, how the reliability layer is
supposed to behave, and why each significant decision was taken. It describes the *design*, not the
current build status.

**For what actually works today, and what has never been run,** see
[08-status-and-gaps.md](08-status-and-gaps.md). **For the work still outstanding,** see
[TODO.md](../../TODO.md) at the repository root.

## How to read this

Roughly in order — each document assumes the ones before it.

| # | Document | What it defines |
|---|----------|-----------------|
| 00 | [Design decisions](00-decisions.md) | Every significant decision with its rationale and consequences (D1–D14), ADR-style. **Start here** if you want to know *why*. |
| 01 | [Architecture](01-architecture.md) | Targets, Swift packages, module layout, process and concurrency model, data flow. |
| 02 | [Wire protocol](02-protocol.md) | **Normative.** Framing, handshake, capability negotiation, the full message catalog with byte layouts, heartbeat, versioning rules. |
| 03 | [Reliability](03-reliability.md) | The liveness detectors, the connection state machine, watchdogs, the failure-mode table, sleep/wake, virtual-display lifecycle. |
| 04 | [Media pipeline](04-media-pipeline.md) | Capture, encode (HEVC + H.264 fallback + adaptive bitrate), decode, present, the virtual display, input capture and injection. |
| 05 | [Security & pairing](05-security-and-pairing.md) | **Normative.** Certificate TLS 1.3, the CPace PAKE, the trust store, input-injection gating, threat model. |
| 06 | [UX & onboarding](06-ux-and-onboarding.md) | Role picker, permission onboarding and the relaunch trap, menu-bar surface, immersive Display, reconnection storytelling. |
| 07 | [Build & distribution](07-build-and-distribution.md) | Universal 2 build, Developer ID signing, notarization and stapling, Sparkle auto-update. |
| 08 | [Status & known gaps](08-status-and-gaps.md) | What is implemented, what is *verified*, and what has never run on hardware. Authoritative where it disagrees with the documents above. |

Documents 02 and 05 are normative: the Rust client is checked against them, and against the
machine-readable vectors in [`../protocol-vectors/`](../protocol-vectors/). Do not edit those
vectors or the Swift reference to make a test pass.

## The one-paragraph summary

Keep the proven core — the private `CGVirtualDisplay` API plus ScreenCaptureKit and VideoToolbox —
because it is the only way to make macOS treat the stream as a genuine extended monitor. Build
around it: one universal, non-sandboxed SwiftUI app with a role picker; a versioned handshake
protocol rather than a fragile fixed header; and the product's actual value — **reconnection and
freeze-recovery that survives a cable pull, a sleep/wake cycle and a half-open socket** — as a
first-class subsystem rather than scattered error handlers.

## Canonical constants

Every timer, size and identifier used across these documents is defined once, in
[03-reliability.md § Constants](03-reliability.md#constants) and
[02-protocol.md § Constants](02-protocol.md#constants). Do not redefine them per module.
