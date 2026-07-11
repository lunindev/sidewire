# 05 — Security & Pairing

Implemented in Phase 3. Read [00 D6](00-review-and-decisions.md) for the decision. The threat this closes is specific and serious: because the Display forwards input that the Source injects with `CGEvent`, **an unauthenticated peer on the LAN gets remote *control* of the primary Mac**, not just a view of it. So this is not "encrypt the video" — it's "don't hand a stranger my keyboard."

## Threat model

In scope (must defend):
- A rogue device on the same LAN/Wi-Fi connecting to a Source and injecting input.
- A passive eavesdropper on the LAN reading screen contents.
- An active MITM on the LAN during pairing.

Out of scope (v1, acceptable):
- A compromised endpoint (if the Mac itself is owned, the game is over).
- Nation-state traffic analysis.
- Physical access to either Mac.

The direct Thunderbolt path is point-to-point and effectively private, but we do **not** special-case it — the same TLS + pairing applies on every transport so there is one code path and Wi-Fi is never the weak default.

## Transport encryption — TLS 1.3

Wrap `NWConnection` in `NWProtocolTLS` (`sec_protocol_options_...`). No CA, no hostnames — this is peer-to-peer:

- Each install generates a long-lived **self-signed certificate / key pair** (P-256), stored in the Keychain, identifying the device (`deviceId`).
- Verify the peer with **public-key pinning** via `sec_protocol_options_set_verify_block`: on first pairing, record the peer's public key; on every later connection, require it to match the pinned key. A changed key → refuse + warn (possible MITM or reinstalled peer → re-pair explicitly).
- TLS 1.3 only; strong cipher suites; disable renegotiation.

## Pairing — PIN that never crosses the wire

First connection to a given peer requires pairing; the goal is to bind the two devices' pinned keys with human-verifiable proof, without ever transmitting the PIN or anything trivially derived from it (the exact Moonlight MITM CVE).

Flow:
1. The **Display** generates and shows a 6-digit PIN (and a QR encoding `deviceId`, host, port, and the PIN) on its idle/waiting screen.
2. The user enters the PIN on the **Source** (or scans the QR).
3. Both sides run a **PAKE (SPAKE2)** using the PIN as the shared low-entropy secret. The PAKE yields a shared high-entropy key **only if both used the same PIN**, and reveals nothing about the PIN to an eavesdropper or MITM. (Implementation: a maintained Swift SPAKE2, or CryptoKit primitives. **Fallback if no clean SPAKE2 is available:** TLS-PSK where the PSK is derived from the PIN via HKDF and used inside the already-established TLS channel, combined with cert pinning — weaker than SPAKE2 against an active MITM at pairing time but acceptable for a LAN v1; prefer SPAKE2.)
4. On success, each side stores the other's **pinned public key + `deviceId` + a human label** in the Keychain trust store. Subsequent connections skip pairing entirely (pinned-key TLS is sufficient) and go straight through.

Rules:
- **The PIN is never sent** as plaintext or as a derived salt/hash on the wire. Only PAKE messages travel.
- A PIN is single-use and short-lived (rotate on each pairing attempt; expire after a few minutes).
- Rate-limit PIN attempts (e.g. lock after 5 wrong entries for a cooldown) to bound online guessing of a 6-digit PIN.

## Trust store

`Pairing/TrustStore.swift`, Keychain-backed:
- keyed by peer `deviceId`; stores pinned public key + label + last-seen.
- `list()`, `isPaired(deviceId)`, `pin(deviceId, key)`, `forget(deviceId)`.
- Surfaced in Settings as "Paired Macs" with a **Forget this Mac** action (revokes trust; next connection re-pairs).

## Input-injection gate

Independent of TLS: `InputInjector` refuses to post any `CGEvent` unless `TrustStore.isPaired(peerDeviceId)` is true for the active session. Even if a bug let an unpaired peer complete a handshake, it could not drive the keyboard/mouse. Video-only from an unpaired peer is likewise refused in v1 (no connection proceeds past `pairing` without success), but this gate is the defense-in-depth backstop specifically for the control channel.

## Optional second factor (owner decision, deferred)

For a public release, an optional "**Allow this Mac?** [Deny] [Allow once] [Always allow]" confirmation on the Display when a *new* Source pairs adds a second, on-device factor. Not required for v1; the PIN already gates first contact. Left as a setting to enable.

## What this is not

No accounts, no cloud, no relay server, no telemetry. Everything is local and peer-to-peer. This is both a privacy selling point and the removal of an entire class of failure — but it is precisely why the LAN auth above is mandatory rather than optional.
