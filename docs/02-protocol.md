# 02 — Wire Protocol v2 — normative

**Status: v2, normative.** This document is the byte-exact, authoritative specification of the
Sidewire wire protocol. It is precise enough to implement a non-Mac (e.g. Rust) peer. The
[`protocol-vectors/`](../protocol-vectors/) golden fixtures are the machine-checkable conformance
suite for everything below; pairing crypto detail lives in [05 — Security & Pairing](05-security-and-pairing.md)
(also normative). Where prose and a vector disagree, it is a bug — file it.

The protocol lives in the `SidewireProtocol` package (pure Swift, no platform-media deps). Design
goals: versioned, forward-compatible (unknown messages are skippable), cheap on the hot path
(binary video/input/heartbeat), flexible on the cold path (JSON handshake/control).

All multi-byte integers are **big-endian (network byte order)** unless stated. Floats are IEEE-754
**big-endian**. All strings are UTF-8.

> **What changed from v1.** v2 is a breaking change (`protocol.major = 2`): certificate-based
> **TLS 1.3** + a channel-bound **PIN proof** replace v1's TLS-1.2 PIN-PSK (see [05](05-security-and-pairing.md));
> input events are now **platform-neutral** (USB-HID usages, not macOS keycodes); the video
> subheader carries a **PTS**; the `FEEDBACK` message is removed; unknown BYE reasons are now
> fatal-for-reconnect. Nothing shipped on v1, so there is no dual-stack — a v1 peer is rejected at
> HELLO.

## Transport framing

Connection lifecycle: **TCP connect → TLS 1.3 handshake (cert-based, mutual auth) → [pairing PIN
proof, first time only] → application handshake → streaming.** TLS and pairing are specified in
[05](05-security-and-pairing.md); everything below rides *inside* the established TLS 1.3 channel.

Every message is a fixed **12-byte header** followed by a payload:

```
 0               1               2               3
 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|     type      |     flags     |           reserved            |   type:UInt8, flags:UInt8, reserved:UInt16
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                            length                             |   length:UInt32  (payload bytes, excl. header)
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                             seq                               |   seq:UInt32     (per-connection monotonic)
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        payload (length bytes)                 |
```

- `type` — message type (catalog below).
- `flags` — per-type bit field; 0 unless the type defines bits (VIDEO does).
- `reserved` — MUST be 0 on send, ignored on receive (room for future header fields without a version bump).
- `length` — payload length in bytes; `0` is valid (e.g. a bare control message). **Reject any frame with `length > MAX_FRAME_BYTES`** (see Constants) as a protocol error → drop the connection. This prevents a corrupt/hostile length from causing an unbounded allocation.
- `seq` — monotonic per connection, per direction, starting at 0, wrapping `0xFFFFFFFF → 0`. Used for loss/gap diagnostics; **not** used for reordering (TCP is ordered).

**Reading rule (forward compatibility):** read the 12-byte header, then read exactly `length`
payload bytes. If `type` is unknown/reserved, **skip** the payload and continue — never treat an
unrecognized `type` as fatal. This is what lets a newer peer talk to an older one.

## Message catalog

| type | name | dir | payload encoding | hot path |
|------|------|-----|------------------|----------|
| `0x01` | `HELLO` | both | JSON | no |
| `0x02` | `HELLO_ACK` | both | JSON | no |
| `0x03` | `CONFIG` | source→display | JSON | no |
| `0x04` | `PAIR_PROOF` | both | binary (32 B HMAC-SHA256) | no |
| `0x05` | `PAIR_ACK` | source→display | empty | no |
| `0x10` | `VIDEO` | source→display | binary (subheader + Annex-B) | **yes** |
| `0x11` | `AUDIO` | *reserved* | — | — |
| `0x20` | `INPUT` | display→source | binary (32 B/event) | **yes** |
| `0x30` | `PING` | both | binary (8 B) | yes |
| `0x31` | `PONG` | both | binary (8 B) | yes |
| `0x40` | `REQUEST_IDR` | display→source | empty | no |
| `0x41` | `LTR_ACK` | display→source | binary (list of UInt16) | no |
| `0x42` | *reserved (was `FEEDBACK`)* | — | — | must be skippable |
| `0x50` | `DISPLAY_INFO` | display→source | JSON | no |
| `0x60` | `PAUSE` | both | JSON `{reason}` | no |
| `0x61` | `RESUME` | both | empty | no |
| `0x6F` | `BYE` | both | JSON `{reason}` | no |
| `0x70`–`0xFF` | *reserved* | — | — | must be skippable |

> **`0x42` was `FEEDBACK`** in early v2 drafts (a ~2 Hz JSON quality report driving adaptive
> bitrate). It was never sent — adaptive bitrate is RTT-driven (from PING/PONG) — so it is removed
> and `0x42` is reserved. A receiver that ever sees `0x42` skips it like any unknown type.

### PAIR_PROOF (`0x04`) / PAIR_ACK (`0x05`)

The channel-bound PIN proof, exchanged **before** HELLO on a first-time pairing connection (a paired
reconnect skips these entirely — no `0x04`/`0x05` on the wire). `PAIR_PROOF` payload is a bare
**32-byte HMAC-SHA256**; `PAIR_ACK` is empty. Sequence: Source → `PAIR_PROOF(clientProof)`; Display
verifies → `PAIR_PROOF(serverProof)`; Source verifies → `PAIR_ACK`; both proceed to HELLO. The
byte-exact key/proof derivation, channel binding, ordering, failure handling (`BYE("auth")`), and
rate limiting (`BYE("rateLimited")`) are specified in [05](05-security-and-pairing.md) (normative)
and pinned by `protocol-vectors/pairing-vectors.json`.

## Handshake

```
Source (dialer / client)                         Display (listener / server)
  │  ── TCP connect ─────────────────────────────▶ │
  │  ══ TLS 1.3 handshake (mutual cert auth) ═════ │   both derive the peer SPKI hash + deviceId
  │                                                 │
  │  [first-time pairing only — see docs/05]        │
  │  ── PAIR_PROOF(clientProof) ──────────────────▶ │   verify → pin Source, reply
  │  ◀────────────────── PAIR_PROOF(serverProof) ── │
  │  ── PAIR_ACK ─────────────────────────────────▶ │   both pin the peer
  │                                                 │
  │  ── HELLO ────────────────────────────────────▶ │   validate (magic/major/role/inputMapping)
  │  ◀──────────────────────────────────── HELLO ── │
  │  ── HELLO_ACK ────────────────────────────────▶ │
  │  ◀────────────────────────────── HELLO_ACK ──── │   then, right after ITS HELLO_ACK:
  │  ◀────────────────────────── DISPLAY_INFO ───── │   (only after validating the Source's HELLO)
  │  ── CONFIG ───────────────────────────────────▶ │
  │  ══ VIDEO ▶  /  ◀ INPUT, PING/PONG … ══════════ │   streaming
```

Both peers send `HELLO` immediately after pairing completes (or immediately after TLS on a paired
reconnect). Order between the two HELLOs is arbitrary; each side replies `HELLO_ACK` on first
receipt so both have the other's capabilities regardless of order.

### HELLO (`0x01`) / HELLO_ACK (`0x02`)

Identical JSON shape; only the frame `type` byte differs. `HELLO_ACK` confirms receipt and carries
the ack'ing peer's capabilities.

```json
{
  "magic": "SIDEWIRE",
  "version": { "major": 2, "minor": 0 },
  "role": "source",                       // or "display"
  "deviceId": "a1b2c3d4e5f6a7b8",         // first 16 bytes of the SPKI-SHA256, lowercase hex (docs/05)
  "deviceName": "Alex — MacBook Pro M4 Max",
  "sessionId": "9B7E...-uuid",            // new per session
  "capabilities": {
    "videoCodecs": ["hevc", "h264"],      // preference order
    "maxWidth": 3456, "maxHeight": 2234,
    "maxFps": 60,
    "ltr": true,
    "audio": false,
    "hdr": false,
    "inputMapping": "hid1"                // wire input encoding; see § INPUT
  }
}
```

**Validation (both peers, on receiving a HELLO/HELLO_ACK):**

1. `magic == "SIDEWIRE"` — else `BYE{reason:"protocol"}` + close.
2. `version.major == 2` **exactly** — else `BYE{reason:"protocol"}` + close (v1 peers rejected here).
   `version.minor` is informational only.
3. Roles complementary (one `source`, one `display`) — else `BYE{reason:"role"}` + close.
4. `capabilities.inputMapping` equals ours (both v2 peers send `"hid1"`) — else `BYE{reason:"protocol"}` + close.
5. **A payload that fails to JSON-decode** at all (HELLO / DISPLAY_INFO / CONFIG) → `BYE{reason:"protocol"}` + close. (Fail loud: never silently drop a malformed handshake message and hang to the connect timeout.)

### CONFIG (`0x03`)

The **source** computes the negotiated configuration = intersection of both capability sets, then
sends `CONFIG`. It does this only after it has both the peer's HELLO **and** the Display's
`DISPLAY_INFO` (for native sizing). If the peers share **no** video codec, the source fails the
handshake with `BYE{reason:"protocol"}` rather than streaming an undecodable codec.

```json
{
  "codec": "hevc",                        // first common codec in the source's preference order
  "width": 2560, "height": 1600,          // capture/encode pixel dimensions (match DISPLAY_INFO)
  "fps": 60,
  "ltr": true,
  "bitrateStartBps": 30000000,
  "bitrateMinBps": 5000000,
  "bitrateMaxBps": 50000000,
  "hiDPI": true                           // create the virtual display HiDPI (2×) vs 1×; optional, default true
}
```

Only after sending `CONFIG` (and, on the display, receiving it) do the peers reach streaming: the
source creates/resizes the virtual display and starts capture. See [04](04-media-pipeline.md) and
[03 § Session states](03-reliability.md#session-state-machine).

### DISPLAY_INFO (`0x50`)

Display → source, JSON. **Sent only after the Display has received and validated the Source's
HELLO** — specifically, right after the Display sends its own `HELLO_ACK`. (This ordering means a
peer the Display would reject never learns the panel description.)

```json
{ "width": 2560, "height": 1600, "scaleFactor": 2.0, "refreshRate": 60, "name": "Built-in Retina Display" }
```

`width`/`height` are the Display's native pixel dimensions; the source uses them (and `scaleFactor`)
to size the virtual display so the extended desktop matches the panel 1:1 (or per the user's chosen
resolution/scale).

### VIDEO (`0x10`)

`flags` bits:

| bit | mask | meaning |
|-----|------|---------|
| 0 | `0x01` | keyframe (IDR) — payload begins with VPS/SPS/PPS parameter sets |
| 1 | `0x02` | LTR frame — *reserved for future loss recovery; senders currently send 0* |
| 2 | `0x04` | LTR-P (recovery) frame — *reserved; senders currently send 0* |

Payload = a **12-byte subheader** (always present) + Annex-B NAL units:

```
off  size field           notes
0    2    ltrToken:UInt16  reserved for future loss recovery; senders currently send 0
2    2    flags:UInt16     reserved; MUST be 0 on send, ignored on receive
4    8    pts:UInt64       capture presentation timestamp, NANOSECONDS on an arbitrary monotonic
                           epoch (the source's capture clock). 0 = unspecified (e.g. keep-alive resend).
12   …    Annex-B NAL units (00 00 00 01 start codes), incl. parameter sets on keyframes
```

- The subheader is always present (even with LTR off); keeps parsing uniform.
- `pts` lets a receiver build a jitter buffer / stats HUD. The reference Mac receiver renders **on
  arrival** (no jitter buffer) and merely exposes the parsed PTS; a foreign client MAY buffer on it.
  The epoch is arbitrary but monotonic within a session — do not assume any relation to wall-clock.
- NAL data is raw HEVC/H.264 Annex-B, exactly as the encoder emits, including in-band parameter sets
  on every keyframe (so a client can join at any keyframe).
- **LTR is reserved.** The `ltrToken`, the two LTR flag bits, and `LTR_ACK` (0x41) are kept in the
  format for a future loss-recovery path but are inert in v2: senders send `ltrToken = 0` and clear
  the LTR flags; recovery today is IDR-based (`REQUEST_IDR`).

### INPUT (`0x20`)

Display → source. A fixed **32-byte** binary record (one INPUT frame MAY batch `length / 32`
records). v2 is **platform-neutral**: keys are USB-HID usages and modifiers are the HID
boot-protocol modifier byte, so a Windows/Linux Display maps its OS events to the same encoding.

```
off  size field              notes
0    1    eventType:UInt8     see InputEventType below
1    1    buttonNumber:UInt8  pointer button index (0 = left, 1 = right, …)
2    1    clickCount:UInt8    click multiplicity (double-click = 2, …)
3    1    modifiers:UInt8     HID boot-protocol modifier bitmask (see below)
4    8    reserved:UInt64     MUST be 0 on send, ignored on receive
12   4    x:Float32           normalized 0..1 within the rendered video rect (top-left origin)
16   4    y:Float32           normalized 0..1 (top-left origin)
20   4    deltaX:Float32      scroll delta, wire unit = PIXELS
24   4    deltaY:Float32      scroll delta, wire unit = PIXELS
28   2    keyCode:UInt16      USB HID keyboard usage ID (Usage Page 0x07); 0 = none / unmapped
30   2    reserved:UInt16     MUST be 0 on send, ignored on receive
```

`InputEventType`: `mouseMove=1, mouseDown=2, mouseUp=3, rightMouseDown=4, rightMouseUp=5,
scrollWheel=6, keyDown=7, keyUp=8, flagsChanged=9, mouseDragged=10, rightMouseDragged=11`.

**`keyCode` — USB HID keyboard usage** (Usage Page `0x07`), e.g. `0x04`='a', `0x28`=Return,
`0x2C`=Space, `0x52`=Up Arrow, `0xE1`=Left Shift. A key with no HID mapping is dropped by the
sender (not sent as an ambiguous 0). The macOS endpoint's reference keycode table (both directions)
is `SidewireProtocol.HIDKeyboardMap`; a foreign endpoint maps its own OS keycodes to the same HID
usages. Non-US layouts/IME: only the HID usage crosses; the **Source's** active layout interprets it.

**`modifiers` — HID boot-protocol modifier byte** (HID usages `0xE0`–`0xE7`):

| bit | mask | modifier |
|-----|------|----------|
| 0 | `0x01` | Left Control |
| 1 | `0x02` | Left Shift |
| 2 | `0x04` | Left Alt |
| 3 | `0x08` | Left GUI (⌘/Win) |
| 4 | `0x10` | Right Control |
| 5 | `0x20` | Right Shift |
| 6 | `0x40` | Right Alt |
| 7 | `0x80` | Right GUI |

Caps Lock is not a modifier bit (it is a normal key, HID usage `0x39`). A sender that cannot
distinguish left/right (e.g. from device-independent flags) reports the left-hand bit.

**Scroll deltas are in pixels** (macOS delivers pixel-precise deltas; `deltaX`/`deltaY` are those
pixel values). A receiver injects them as pixel-unit scroll. Coordinates are normalized to the
**rendered video rect** (the aspect-fit letterbox), so clicks land on-target when the stream aspect
differs from the panel. **Input is dropped unless the peer is paired** ([05](05-security-and-pairing.md)).

### PING / PONG (`0x30` / `0x31`)

Payload is an 8-byte `UInt64`: the sender's **monotonic** clock in nanoseconds. `PONG` echoes the
exact 8 bytes received in the `PING`. The originator computes `RTT = now − echoedValue` on **its
own clock**, so there is no cross-machine clock skew. One-way latency ≈ `RTT / 2`.

### Control messages

- **`REQUEST_IDR` (`0x40`)** — display → source, empty. Sent on first connect, after a decode
  gap/error, or after rebuilding the decoder. Source forces a keyframe. Use sparingly.
- **`LTR_ACK` (`0x41`)** — display → source. Payload = `count:UInt16` followed by `count` × `UInt16`
  acknowledged LTR tokens. *Reserved with LTR (see § VIDEO); not sent in v2.*
- **`PAUSE` (`0x60`) / `RESUME` (`0x61`)** — either peer announces an impending sleep
  (`PAUSE{reason:"sleep"}`) so the other doesn't mistake silence for death, then `RESUME` on wake.
  See [03 § Sleep/wake](03-reliability.md#sleepwake).

## Heartbeat / liveness contract

Both peers run an application-level heartbeat with a dead-peer watchdog (the primary liveness
detector — TCP's own default is ~2 h, and a blocked send can hang forever). Timing:

- **Send interval:** each peer sends a `PING` every `HEARTBEAT_INTERVAL = 0.5 s`.
- **Liveness rule (normative):** a peer MUST transmit **something** (any frame — `PING`, `VIDEO`,
  `INPUT`, …) at least every `HEARTBEAT_TIMEOUT = 2.5 s`. **Any inbound frame** resets the peer's
  watchdog (not just `PONG`). If a peer receives nothing for `> 2.5 s`, it declares the peer dead
  and closes with `BYE`-equivalent reason `"timeout"`.
- A foreign implementation therefore MUST keep the link warm — echo `PONG`s promptly and, on a
  static screen with no video, rely on the `0.5 s` `PING` cadence to stay under the `2.5 s` budget.

## BYE (`0x6F`) and the reason registry

Graceful close with a reason: `{ "reason": "<token>" }`. The reason governs whether the *dialing*
side (Source) auto-reconnects. **v2 default: an unknown reason is fatal-for-reconnect** (a
foreign/newer peer's unrecognized reason must not cause an endless reconnect loop). Reconnection is
gated by an explicit allowlist of **transient** reasons.

**Transient — the Source re-dials (re-resolving Bonjour):**

| reason | meaning |
|--------|---------|
| `timeout` | connect/handshake bound or heartbeat silence; the peer may return |
| `transport` | canonical low-level transport failure (TCP reset/refused/abort, interface drop, framing error) |
| `wake` | local sleep/wake; the Source rebuilds the virtual display + capture |
| `capture-stall` | Source ScreenCaptureKit stream died |
| `encoder-stall` | Source encoder wedged (capture delivering, no output) |
| `no-video` | Display never received a first decoded frame within the grace budget |
| `no-frame` | Display video pipeline wedged after streaming started |

A **`nil`/absent** reason (a clean transport close) is also treated as transient.

**Fatal — the Source stops and surfaces a human message (no auto-reconnect):**

| reason | meaning |
|--------|---------|
| `user` | the peer disconnected on purpose |
| `protocol` | version/magic/codec/input-mapping mismatch, or a malformed handshake message |
| `role` | both Macs picked the same role |
| `error` | a peer-signalled fatal error |
| `auth` | wrong PIN (pairing proof failed) — see [05](05-security-and-pairing.md) |
| `keyChanged` | a pinned peer presented a different public key (possible MITM / reinstall) |
| `rateLimited` | too many wrong PIN attempts; the Display locked out pairing |
| `superseded` | a newer Source displaced this one on the Display (newest-wins) |
| *anything else* | **unknown ⇒ fatal** (do not reconnect) |

A `BYE` is flushed before the socket is torn down so the peer receives the reason rather than a bare
reset. Note that a genuine network failure surfaces to the reconnect logic as the canonical
`transport` reason, not as an opaque OS error string, precisely so it stays reconnect-eligible under
the unknown-is-fatal rule.

## Protocol evolution policy (normative)

Within a major version, the wire must evolve without breaking older peers. Senders and receivers
MUST obey:

1. **Major must match exactly; minor is informational.** A peer accepts only an equal-`major` peer
   (v2 ↔ v2). `minor` is advisory (bump it for backward-compatible additions); never gate behavior
   on a specific `minor` — probe capabilities instead.
2. **New JSON fields are optional-with-defaults.** Any field beyond the v2 *required* set MUST be
   optional on decode and carry a sensible default when absent (e.g. `capabilities.inputMapping`
   defaults to `"hid1"`, `config.hiDPI` to `true`). Senders **MUST NOT** add a *required* field
   within a major version.
3. **Decoders MUST ignore unknown JSON fields.** Never fail a decode because of an unrecognized key.
4. **Receivers MUST skip unknown message types** (and the reserved `0x70`–`0xFF` range, and reserved
   `0x11`/`0x42`) using the header `length`, never treating them as fatal.
5. **Reserved header/subheader bytes** (frame `reserved:UInt16`, the input record's reserved fields,
   the video subheader `flags`/`ltrToken`) MUST be 0 on send and ignored on receive.
6. A change that violates any of the above (new required field, repurposed byte with breaking
   semantics, incompatible framing) requires a **major** bump and is out of scope for v2.

## Conformance vectors

[`protocol-vectors/`](../protocol-vectors/) contains language-neutral JSON fixtures — the conformance
suite for a foreign implementation. `frame`/`input`/`video`/`pairing` vectors are byte-exact;
`message` (JSON) vectors are matched semantically (JSON key order is not significant). They are
generated from the Swift tests and re-verified on every `swift test`, so the spec above and the code
cannot silently drift. See [`protocol-vectors/README.md`](../protocol-vectors/README.md).

## Constants {#constants}

Defined once in `SidewireProtocol`; session/timing constants live in
[03 § Constants](03-reliability.md#constants) and `SessionConstants`.

| name | value | meaning |
|------|-------|---------|
| `PROTOCOL_MAGIC` | `"SIDEWIRE"` | handshake magic |
| `PROTOCOL_MAJOR` | `2` | breaking version (v2 = cert-TLS 1.3 + PIN proof, HID input, PTS) |
| `PROTOCOL_MINOR` | `0` | additive version (informational) |
| `FRAME_HEADER_BYTES` | `12` | fixed header size |
| `MAX_FRAME_BYTES` | `16 * 1024 * 1024` | reject larger; guards allocation |
| `INPUT_RECORD_BYTES` | `32` | one input event |
| `VIDEO_SUBHEADER_BYTES` | `12` | ltrToken(2) + flags(2) + pts(8) |
| `HEARTBEAT_INTERVAL` | `0.5 s` | PING cadence |
| `HEARTBEAT_TIMEOUT` | `2.5 s` | max silence before declaring the peer dead |
| `BONJOUR_SERVICE_TYPE` | `"_sidewire._tcp"` | discovery |
| `DEFAULT_PORT` | `0` (ephemeral) | advertise the OS-assigned port via Bonjour; `5005` only as a manual-IP fallback |

> **Migration note:** the framing, Bonjour service type, and security are all incompatible with the
> old MacDisplay build. There is no backward compatibility — both machines run the new app.
