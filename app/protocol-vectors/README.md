# Sidewire protocol vectors (v2)

Language-neutral **golden vectors** — the conformance suite for any non-Swift implementation of the
Sidewire wire protocol (the Rust/Windows/Linux Display client, primarily). They pin the byte-exact
encoding of every hot-path structure and the pairing crypto so a foreign implementation can test
against them with no Swift toolchain.

The normative spec these vectors accompany is [`docs/02-protocol.md`](../docs/02-protocol.md) (wire)
and [`docs/05-security-and-pairing.md`](../docs/05-security-and-pairing.md) (pairing crypto). When
this README and the docs disagree, the docs win; when a vector and the docs disagree, it's a bug —
report it.

## Files

| file | covers | match rule |
|------|--------|-----------|
| `frame-vectors.json` | 12-byte frame header + payload framing, per message type, edge lengths, seq wrap, an unknown/reserved type | **byte-exact** (`frameHex`) |
| `input-vectors.json` | 32-byte `INPUT` records (mouse, scroll, keys, modifiers) | **byte-exact** (`hex`) |
| `video-vectors.json` | `VIDEO` payload = 12-byte subheader (ltrToken, flags, **pts**) + Annex-B | **byte-exact** (`payloadHex`) |
| `message-vectors.json` | canonical JSON control messages (HELLO, CONFIG, DISPLAY_INFO, BYE) | **semantic** (decode + compare fields; see below) |
| `pairing-vectors.json` | CPace PAKE: `channelBinding`, `sid`, `generator`, shares, `K`, `ISK`, `mac_key`, confirmation tags from fixed inputs + injected scalars | **byte-exact** (hex) |

All integers on the wire are **big-endian**; floats are IEEE-754 big-endian; all hex is lowercase.

## How to consume them

Every file is `{ "note": "...", "vectors"/... : [ { "name", "description", <inputs>, <expected hex> } ] }`.

- **Binary structures** (`frame`, `input`, `video`, `pairing`): reconstruct the bytes from the input
  fields with your implementation and assert they equal the expected hex. For decoders, do the
  reverse: parse the hex and assert you recover the input fields.
- **JSON messages** (`message-vectors.json`): match **semantically**. JSON key order is *not*
  significant and is *not* fixed on the wire (the reference encoder does not even stabilize it), so
  there is deliberately no byte-exact hex. Each entry's `message` object is the canonical field set:
  serialize your equivalent struct, and assert a round-trip through your JSON codec preserves those
  fields. Decoders **must ignore unknown fields**, and fields beyond the v2 required set are
  optional-with-defaults (e.g. `capabilities.inputMapping` defaults to `"hid1"`, `config.hiDPI` to
  `true`) — see the evolution policy in docs/02.

### Pairing crypto (`pairing-vectors.json`)

The pairing exchange is **CPace**, ciphersuite `CPACE-X25519-SHA512-ELLIGATOR2`
(`draft-irtf-cfrg-cpace-21`). Given a fixed `pin`, `clientSPKI` (32 B), `serverSPKI` (32 B), and the
two injected scalars `scalarA`/`scalarB`, a conformant implementation must reproduce every hex field:

```
CI   = channelBinding = SHA-256( clientSPKI ‖ serverSPKI )   // 32 B, client-then-server
sid  = SHA-256( channelBinding )                             // 32 B, deterministic
PRS  = utf8(pin) ; ADa = ADb = ""                            // Source = initiator A, Display = responder B
g    = calculate_generator(PRS, CI, sid)                     // SHA-512 gen-string → first 32 B → decodeUCoordinate → Elligator2
Ya   = X25519(scalarA, g)  ;  Yb = X25519(scalarB, g)        // PAIR_MSG payloads
K    = X25519(scalarA, Yb) = X25519(scalarB, Ya)             // abort if all-zero (low-order point)
ISK  = SHA-512( lv_cat("CPace255_ISK", sid, K) ‖ lv_cat(Ya,ADa) ‖ lv_cat(Yb,ADb) )   // 64 B
mac_key   = SHA-512( "CPaceMac" ‖ sid ‖ ISK )                // 64 B
confirmA  = HMAC-SHA512( mac_key, lv_cat(Ya, ADa) )          // Ta — PAIR_CONFIRM from Source
confirmB  = HMAC-SHA512( mac_key, lv_cat(Yb, ADb) )          // Tb — PAIR_CONFIRM from Display
```

`lv_cat` prepends each field's LEB128 length; transcript ordering is initiator-first (`transcript_ir`).
Confirmation-tag comparisons on the wire **must be constant-time**. The `scalarA`/`scalarB` fields are
the **RNG-injection point** that makes these vectors deterministic — a live session samples fresh
random scalars, so only the derivations (not `Ya/Yb/K/ISK`) are reproducible there. The
`clientSPKI`/`serverSPKI` are fixed test patterns (`00..1f`, `20..3f`), not real certificates; in a
live session they are the SHA-256 SPKI fingerprints of the two leaf certs (docs/05). Sidewire's
implementation is additionally verified byte-for-byte against the CPace draft's own published
X25519/SHA-512 test vectors.

## Regenerating

The vectors are generated **from the Swift tests** and checked in. To regenerate after an
intentional encoding change:

```sh
cd Packages/SidewireProtocol && SIDEWIRE_WRITE_VECTORS=1 swift test   # frame/input/message/video
cd Packages/SidewireCore     && SIDEWIRE_WRITE_VECTORS=1 swift test   # pairing
```

A plain `swift test` (no env var) **verifies** the checked-in files still match the current
encoding, so any accidental wire drift fails CI until the vectors are regenerated on purpose.
