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
| `pairing-vectors.json` | channel-bound PIN proof: `channelBinding`, `K`, `clientProof`, `serverProof` from fixed inputs | **byte-exact** (hex) |

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

Given a fixed `pin`, `clientSPKI` (32 B), and `serverSPKI` (32 B), a conformant implementation must
reproduce every hex field:

```
channelBinding = SHA-256( clientSPKI ‖ serverSPKI )                       // 32 B, client-then-server
K              = HKDF-SHA256( IKM=utf8(pin), salt=saltAscii,              // 32 B
                              info=channelBinding, L=32 )
clientProof    = HMAC-SHA256( K, utf8(clientLabelAscii) )                 // 32 B — the Source sends this
serverProof    = HMAC-SHA256( K, utf8(serverLabelAscii) )                 // 32 B — the Display replies with this
```

Proof comparisons on the wire **must be constant-time**. The `clientSPKI`/`serverSPKI` in the
vectors are fixed test patterns (`00..1f`, `20..3f`), not real certificates; in a live session they
are the SHA-256 SPKI fingerprints of the two leaf certs (docs/05).

## Regenerating

The vectors are generated **from the Swift tests** and checked in. To regenerate after an
intentional encoding change:

```sh
cd Packages/SidewireProtocol && SIDEWIRE_WRITE_VECTORS=1 swift test   # frame/input/message/video
cd Packages/SidewireCore     && SIDEWIRE_WRITE_VECTORS=1 swift test   # pairing
```

A plain `swift test` (no env var) **verifies** the checked-in files still match the current
encoding, so any accidental wire drift fails CI until the vectors are regenerated on purpose.
