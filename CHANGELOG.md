# Changelog

All notable changes to Sidewire. Sections below the first are generated at release time
(`pnpm version:patch|minor|major`) from Conventional Commit messages.

## 0.1.0

First public snapshot of the source. **Not a release:** there are no binaries, nothing is signed or
notarized, and the software has never run on two physical Macs.

### Added

- A universal macOS app with a Source/Display role picker: creates a virtual display, captures and
  encodes it (hardware HEVC, H.264 fallback), streams it, and forwards keyboard and mouse.
- Protocol v2 — certificate-based TLS 1.3 with a CPace PAKE for pairing, so the six-digit PIN never
  crosses the wire and cannot be brute-forced offline from a captured session.
- Reliability as a subsystem: application-level heartbeat, no-frame and encoder-stall watchdogs, a
  recovery ladder, and sleep/wake handling.
- RTT-driven adaptive bitrate, an out-of-band cursor feed, one-click Thunderbolt connect, permission
  onboarding, a Settings pane, menu-bar-only mode, and Sparkle auto-update (opt-in, off by default).
- A native Rust Display client for Windows and Linux that reproduces the protocol byte for byte
  against the shared conformance vectors. No binary has been built for either platform.

### Notes

- Licensed GPL-3.0-or-later.
- Build from source; see the [README](README.md). Outstanding work is tracked in [TODO.md](TODO.md).
