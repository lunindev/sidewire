# 02 — Wire Protocol v1

The protocol lives in the `SidewireProtocol` package (pure Swift, no platform-media deps). It replaces the current 13-byte header. Design goals: versioned, forward-compatible (unknown messages are skippable), cheap on the hot path (binary video/input/heartbeat), flexible on the cold path (JSON handshake/control).

All multi-byte integers are **big-endian (network byte order)** unless stated. All strings are UTF-8.

## Transport framing

Every message is a fixed 12-byte header followed by a payload:

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
- `flags` — per-type bit field; 0 unless the type defines bits (VIDEO uses them).
- `reserved` — must be 0 on send, ignored on receive (room for future header fields without a version bump).
- `length` — payload length in bytes; `0` is valid (e.g. a bare control message). **Bounded: reject any frame with `length > MAX_FRAME_BYTES`** (see Constants) as a protocol error → drop connection. This prevents a corrupt/hostile length from causing an unbounded allocation.
- `seq` — monotonic per connection, per direction, starting at 0. Used for loss/gap diagnostics and to correlate feedback; **not** used for reordering (TCP is ordered).

**Reading rule (forward compatibility):** read the 12-byte header, then read exactly `length` payload bytes. If `type` is unknown, **skip** the payload and continue. Never treat an unknown type as fatal. This is what lets a newer peer talk to an older one.

## Message catalog

| type | name | dir | payload encoding | hot path |
|------|------|-----|------------------|----------|
| `0x01` | `HELLO` | both | JSON | no |
| `0x02` | `HELLO_ACK` | both | JSON | no |
| `0x03` | `CONFIG` | source→display | JSON | no |
| `0x04` | `PAIR_PROOF` | both | binary (32 B HMAC-SHA256) | no |
| `0x05` | `PAIR_ACK` | source→display | empty | no |
| `0x10` | `VIDEO` | source→display | binary (Annex-B, +LTR subheader) | **yes** |
| `0x11` | `AUDIO` | *reserved* | — | — |
| `0x20` | `INPUT` | display→source | binary (32 B/event) | **yes** |
| `0x30` | `PING` | both | binary (8 B) | yes |
| `0x31` | `PONG` | both | binary (8 B) | yes |
| `0x40` | `REQUEST_IDR` | display→source | empty | no |
| `0x41` | `LTR_ACK` | display→source | binary (list of UInt16) | no |
| `0x42` | `FEEDBACK` | display→source | JSON | no (≈2 Hz) |
| `0x50` | `DISPLAY_INFO` | display→source | JSON | no |
| `0x60` | `PAUSE` | both | JSON `{reason}` | no |
| `0x61` | `RESUME` | both | empty | no |
| `0x6F` | `BYE` | both | JSON `{reason}` | no |
| `0x70`–`0xFF` | *reserved* | — | — | must be skippable |

### PAIR_PROOF (`0x04`) / PAIR_ACK (`0x05`)

The channel-bound PIN proof, exchanged **before** HELLO on a first-time pairing connection (a paired reconnect skips these entirely). `PAIR_PROOF` payload is a bare **32-byte HMAC-SHA256**; `PAIR_ACK` is empty. Sequence: Source → `PAIR_PROOF(clientProof)`; Display verifies → `PAIR_PROOF(serverProof)`; Source verifies → `PAIR_ACK`; both then proceed to HELLO. The byte-exact key/proof derivation, channel binding, ordering, failure handling (`BYE("auth")`), and rate limiting (`BYE("rateLimited")`) are specified in [05 — Security & Pairing](05-security-and-pairing.md) (normative).

### Handshake

Connection lifecycle: TCP connect → **TLS 1.3 handshake (cert-based, mutual auth)** → **pairing proof** (first time only) → **application handshake** below → streaming. See [05](05-security-and-pairing.md).

1. **Both peers send `HELLO`** immediately after pairing completes (or immediately after TLS on a paired reconnect).

```json
{
  "magic": "SIDEWIRE",
  "protocol": { "major": 1, "minor": 0 },
  "role": "source",                      // or "display"
  "deviceId": "F1C2...-stable-uuid",     // stable per install, in Keychain
  "deviceName": "Alex — MacBook Pro M4 Max",
  "sessionId": "9B7E...-uuid",           // new per session; used for resume
  "capabilities": {
    "videoCodecs": ["hevc", "h264"],     // in preference order
    "maxWidth": 3456, "maxHeight": 2234,
    "maxFps": 60,
    "ltr": true,
    "audio": false,
    "hdr": false
  }
}
```

2. Each peer validates: `magic == "SIDEWIRE"`, `protocol.major == 2` (major mismatch → `BYE{reason:"protocol"}` + close; v1 peers are rejected here), and that roles are complementary (one `source`, one `display`; two of the same → `BYE{reason:"role"}`). It replies **`HELLO_ACK`** with the same shape (no re-negotiation needed; `HELLO_ACK` mainly confirms receipt and carries the ack'ing peer's capabilities if it hadn't sent them yet).

3. The **source** computes the negotiated configuration = intersection of both capability sets, then sends **`CONFIG`**:

```json
{
  "codec": "hevc",                       // first common codec in source's preference order
  "width": 2560, "height": 1600,         // capture/encode dimensions (match display native, see DISPLAY_INFO)
  "fps": 60,
  "ltr": true,
  "bitrateStartBps": 30000000,
  "bitrateMinBps": 5000000,
  "bitrateMaxBps": 50000000
}
```

Only after the source has both the display's `DISPLAY_INFO` (native resolution) and sent `CONFIG` does it create/resize the virtual display and start capture. See [04](04-media-pipeline.md) and [03 § Session states](03-reliability.md#session-state-machine).

**Version rule:** bump `minor` for backward-compatible additions (new optional fields, new skippable message types). Bump `major` only for a breaking framing/semantics change. Peers must accept any equal-major, any-minor peer and simply ignore fields/messages they don't understand.

### VIDEO (`0x10`)

`flags` bits:

| bit | meaning |
|-----|---------|
| 0 (`0x01`) | keyframe (IDR) — payload begins with VPS/SPS/PPS parameter sets |
| 1 (`0x02`) | LTR frame — this frame was marked as a long-term reference; `ltrToken` valid |
| 2 (`0x04`) | LTR-P frame — a P-frame that references a known-good acknowledged LTR frame (recovery frame) |

Payload:

```
+----------------+----------------+------------------------------------+
| ltrToken:UInt16| reserved:UInt16|  Annex-B NAL units (0x00000001 ...) |
+----------------+----------------+------------------------------------+
```

- The 4-byte video subheader is **always present** (even when LTR off; then `ltrToken=0`, bits 1/2 clear). Keeps parsing uniform.
- `ltrToken` identifies the long-term reference this frame establishes (bit 1) — the receiver will acknowledge it via `LTR_ACK`.
- NAL data is raw HEVC/H.264 Annex-B with `00 00 00 01` start codes, exactly as the current encoder emits, including parameter sets on keyframes.

### INPUT (`0x20`)

To avoid the current JSON-per-event cost on mouse-move storms, input events are a fixed **32-byte** binary record. A single INPUT message may carry `length / 32` events (coalesced moves may be batched, though v1 may send one per message).

```
offset size field           notes
0      1    eventType:UInt8  see InputEventType below
1      1    buttonNumber:UInt8
2      1    clickCount:UInt8
3      1    flags:UInt8       reserved
4      8    modifierFlags:UInt64
12     4    x:Float32         normalized 0..1 within Display content view
16     4    y:Float32         normalized 0..1 (top-left origin)
20     4    deltaX:Float32    scroll/drag deltas
24     4    deltaY:Float32
28     2    keyCode:UInt16
30     2    reserved:UInt16
```

`InputEventType`: `mouseMove=1, mouseDown=2, mouseUp=3, rightMouseDown=4, rightMouseUp=5, scrollWheel=6, keyDown=7, keyUp=8, flagsChanged=9, mouseDragged=10, rightMouseDragged=11` (unchanged from today, so the mapping logic ports directly).

Normalized coordinates keep the mapping display-resolution-independent; the source maps `(x,y)` onto the virtual display's `CGDisplayBounds` (see current `InputInjector.mapToDisplay`). **Input is dropped unless the peer is paired** ([05](05-security-and-pairing.md)).

### PING / PONG (`0x30` / `0x31`)

Payload is an 8-byte `UInt64`: the sender's **monotonic** clock in nanoseconds (`DispatchTime.now().uptimeNanoseconds`). `PONG` echoes the exact bytes received in the `PING`. The originating peer computes `RTT = now − echoedValue` on **its own clock**, so there is no cross-machine clock skew (fixes the current bogus wall-clock latency). One-way latency estimate = `RTT / 2`. Both peers send PINGs on `HEARTBEAT_INTERVAL`; missing `HEARTBEAT_MISS_LIMIT` PONGs declares the peer dead (see [03](03-reliability.md)).

### Control messages

- **`REQUEST_IDR` (`0x40`)** — display → source, empty payload. Sent (a) on first connect, (b) after a decode gap/error, (c) after rebuilding the decoder. Source responds by forcing a keyframe (`kVTEncodeFrameOptionKey_ForceKeyFrame`). Use sparingly — prefer LTR recovery.
- **`LTR_ACK` (`0x41`)** — display → source. Payload = `count:UInt16` followed by `count` × `UInt16` acknowledged LTR tokens. Lets the source drive `ForceLTRRefresh` against a frame it knows the receiver has. See [04 § Encoder](04-media-pipeline.md#encoder).
- **`FEEDBACK` (`0x42`)** — display → source, ~2 Hz, JSON. Drives adaptive bitrate.

```json
{ "lossPct": 0.4, "jitterMs": 3.1, "decodeQueue": 1, "presentedFps": 59, "rttMsEstimate": 8 }
```

- **`DISPLAY_INFO` (`0x50`)** — display → source, sent right after `HELLO_ACK`, JSON:

```json
{ "width": 2560, "height": 1600, "scaleFactor": 2.0, "refreshRate": 60, "name": "Built-in Retina Display" }
```

`width/height` are the Display's native pixel dimensions; the source uses them to size the virtual display so the extended desktop matches the Display's panel 1:1 (or per the resolution the user picked).

- **`PAUSE` (`0x60`) / `RESUME` (`0x61`)** — either peer announces it is about to sleep (`PAUSE{reason:"sleep"}`) so the other doesn't mistake the silence for death, then `RESUME` on wake. See [03 § Sleep/wake](03-reliability.md#sleepwake).
- **`BYE` (`0x6F`)** — graceful close with a reason. Known reasons: `"user"`, `"protocol"`, `"role"`, `"error"`, `"superseded"`, and the pairing/security reasons `"auth"` (wrong PIN), `"keyChanged"` (pinned peer's key changed), `"rateLimited"` (too many wrong PINs) — see [05](05-security-and-pairing.md). All of these are fatal-for-reconnect (the receiver should not auto-reconnect); an unknown reason is treated conservatively as fatal too.

## Constants {#constants}

Defined once in `SidewireProtocol`; media/timing constants that belong to the session live in [03 § Constants](03-reliability.md#constants).

| name | value | meaning |
|------|-------|---------|
| `PROTOCOL_MAGIC` | `"SIDEWIRE"` | handshake magic |
| `PROTOCOL_MAJOR` | `2` | breaking version (v2 = cert-TLS 1.3 + PIN proof, [05](05-security-and-pairing.md)) |
| `PROTOCOL_MINOR` | `0` | additive version |
| `FRAME_HEADER_BYTES` | `12` | fixed header size |
| `MAX_FRAME_BYTES` | `16 * 1024 * 1024` | reject larger; guards allocation |
| `BONJOUR_SERVICE_TYPE` | `"_sidewire._tcp"` | discovery (was `_macdisplay._tcp`) |
| `DEFAULT_PORT` | `0` (ephemeral) | advertise the OS-assigned port via Bonjour; `5005` only as a manual-IP fallback |
| `INPUT_RECORD_BYTES` | `32` | one input event |

> **Migration note:** the Bonjour service type and port change from the old app, and the framing is incompatible. There is no need for backward compatibility with the old MacDisplay build — both machines run the new app.
