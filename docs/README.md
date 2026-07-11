# Sidewire — Specification

**Sidewire** turns a spare Mac into a real *extended* display for your primary Mac, over a direct Thunderbolt cable or over Wi-Fi. One universal app; you pick **Source** or **Display** at launch.

This directory is the implementation specification. It is the source of truth for the rebuild of the app previously called *MacDisplay*. It was produced from a research pass (competitive landscape, macOS capture/virtual-display tech, transport & reconnection, video pipeline, reliability, distribution, UX) plus a 2026 verification pass, then an independent critical review that made the final decisions recorded here.

> **Status:** design complete, implementation not started. Target reader: the engineer (human or model) implementing each phase.

## How to read this

Read in order. Each document assumes you've read the ones before it.

| # | Document | What it fixes / defines |
|---|----------|-------------------------|
| 00 | [Review & Decisions](00-review-and-decisions.md) | Critical review of the prior plan; every final decision + rationale (ADR-style); what changed and why. **Read this first.** |
| 01 | [Architecture](01-architecture.md) | Targets, Swift packages, module layout, process model, concurrency model, data flow, directory structure. |
| 02 | [Wire Protocol v1](02-protocol.md) | Framing, handshake, capability negotiation, full message catalog with byte layouts, heartbeat, LTR-ack, IDR-request, session resume, versioning rules. |
| 03 | [Reliability](03-reliability.md) | The three liveness detectors, the connection state machine (states/transitions/timers), watchdogs, the failure-mode table, sleep/wake, virtual-display lifecycle. **This is the core of the product.** |
| 04 | [Media Pipeline](04-media-pipeline.md) | Capture (SCK 420v), encode (HEVC-LL + LTR + H.264 fallback + adaptive bitrate), decode (+`requiresFlushToResumeDecoding`), present (ASBDL/DisplayImmediately), virtual display (helper subprocess, mode-list guardrails), input capture/inject, sender energy budget. |
| 05 | [Security & Pairing](05-security-and-pairing.md) | TLS 1.3, PIN pairing (PIN never on the wire), Keychain trust store, input-injection gating, threat model. |
| 06 | [UX & Onboarding](06-ux-and-onboarding.md) | Role picker, permission onboarding (Screen Recording / Accessibility / Local Network + the relaunch trap), menu-bar surface, immersive receiver, HUD, reconnection storytelling. |
| 07 | [Roadmap & Phases](07-roadmap-and-phases.md) | Phases 0–5 with goals, task checklists, **acceptance criteria**, and verification steps on the real M4 Max ↔ i9 pair. **Implement in this order.** |
| 08 | [Build & Distribution](08-build-and-distribution.md) | Universal 2 build, Developer ID signing, notarization, stapling, Sparkle auto-update, CI. |

## The one-paragraph summary

Keep the proven core (private `CGVirtualDisplay` + ScreenCaptureKit + VideoToolbox HEVC) — it is the only way to make macOS treat the stream as a real extended monitor, and it is still current in 2026. Rebuild *around* it: collapse the two apps into one universal, non-sandboxed, Developer-ID-notarized SwiftUI app with a role picker; replace the fragile 13-byte TCP header with a versioned handshake protocol; and make the product's actual value — **reconnection and freeze-recovery that survives a cable pull, a sleep/wake, and a half-open socket** — a first-class subsystem built on an application-level heartbeat, `NWPathMonitor`, tuned TCP keepalive with a finite `connectionDropTime`, and a receiver no-frame watchdog decoupled from video cadence. Scope is **Mac ↔ Mac only**; the protocol stays versioned (cheap) but no cross-platform, QUIC, or mobile work is in this plan.

## Canonical constants

All timers, sizes, and identifiers referenced across these docs are defined once in [03-reliability.md § Constants](03-reliability.md#constants) and [02-protocol.md § Constants](02-protocol.md#constants). Do not redefine them per-module; import from a single `SidewireConstants` source.
