# 05 — Security & Pairing (protocol v2)

Implemented in Phase 7a (cert-TLS 1.3 + trust store) and Phase 7c (**CPace PAKE** for pairing, replacing the 7a HMAC PIN proof). Read [00 D6](00-review-and-decisions.md), [09 §D11](09-next-stage.md), and [09 open-question 5](09-next-stage.md) for the decisions. The threat this closes is specific and serious: because the Display forwards input that the Source injects with `CGEvent`, **an unauthenticated peer on the LAN gets remote *control* of the primary Mac**, not just a view of it. So this is not "encrypt the video" — it's "don't hand a stranger my keyboard."

This document is **normative for the wire** and precise enough to implement a non-Mac (Rust) client. Everything here is portable — no Apple-specific crypto is on the wire; the Apple-specific parts (Keychain, `SecIdentity`, Network.framework) are implementation notes for the Mac side only.

> **What changed from v1.** v1 used TLS **1.2** with a plain external PSK derived from the PIN (`TLS_PSK_WITH_AES_128_GCM_SHA256`) — no forward secrecy, offline-brute-forceable from a passive capture, no trust store, no rate limiting. v2 replaces it with **certificate-based TLS 1.3 + a balanced PAKE (CPace) channel-bound to the TLS session + a Keychain trust store**. Nothing shipped on v1, so there is no dual-stack: a v1 peer is rejected at HELLO (`protocol.major` bumped to **2**).
>
> **Pairing sub-protocol change within v2 (Phase 7c).** Phase 7a shipped a channel-bound *HMAC PIN proof* (`HMAC(HKDF(PIN, channelBinding))`). That stopped proof *relay* but not *offline PIN guessing* by an active on-path attacker (see below). Phase 7c replaces it with **CPace**, a balanced PAKE, so a wrong PIN never yields anything offline-crackable. The wire messages `0x04`/`0x05` were repurposed (`PAIR_PROOF`/`PAIR_ACK` → `PAIR_MSG`/`PAIR_CONFIRM`); `protocol.major` stays **2** (nothing shipped). See [docs/02 changelog](02-protocol.md).

## Threat model

In scope (must defend):
- A rogue device on the same LAN/Wi-Fi connecting to a Source and injecting input **without the PIN**.
- A passive eavesdropper on the LAN reading screen contents (now also forward-secret).
- A **passive** attacker or an **off-path** attacker during pairing: cannot recover the PIN or impersonate a peer.
- An **active MITM that terminates TLS toward the Source at pairing time.** With CPace, each PIN guess costs one **online** interaction (a wrong PIN produces an unrelated CPace shared secret, so key confirmation simply fails); the attacker learns nothing offline-crackable from a captured exchange. The Display's rate limiter then bounds those online guesses (5 failures → lockout). This closes the gap the Phase-7a HMAC proof left open.

Out of scope (v1/v2, acceptable): a compromised endpoint; nation-state traffic analysis; physical access to either Mac. (An active on-path attacker at pairing time is now **in scope / defended** — see above — not a residual risk.)

The direct Thunderbolt path is point-to-point and effectively private, but we do **not** special-case it — the same TLS + pairing applies on every transport so there is one code path and Wi-Fi is never the weak default.

## Device identity

Each install generates a long-lived **P-256** key pair and a minimal **self-signed X.509 certificate**, persisted (Mac: in the Keychain). The certificate is an opaque key carrier — there is no CA, no hostname, no chain to validate:

- Curve **NIST P-256 (secp256r1)**, signature **ecdsa-with-SHA256**.
- `version v3`, `subject == issuer == CN=Sidewire`, `notBefore = now − 1h`, `notAfter = now + 20y`, a random serial. Extensions are cosmetic (BasicConstraints CA:FALSE, KeyUsage digitalSignature). A client MAY present any self-signed P-256 leaf; **only the public key matters**.
- **`spkiHash`** = `SHA-256` over the DER **SubjectPublicKeyInfo** (RFC 7469 "SPKI Fingerprint"). For P-256 the SPKI is the standard 91-byte `SEQUENCE { AlgorithmIdentifier(ecPublicKey, prime256v1), BIT STRING(0x04‖X‖Y) }` that OpenSSL `i2d_PUBKEY` and swift-crypto `P256.PublicKey.derRepresentation` both produce. This 32-byte value is what the trust store pins.
- **`deviceId`** = the first **16 bytes** of `spkiHash`, lowercase hex (32 chars). The identity is therefore **self-authenticating**: a peer cannot claim a `deviceId` it doesn't hold the private key for, because the id is derived from the key. This is what lets the trust store be keyed by `deviceId` and advertised in HELLO / Bonjour without being spoofable.

*Mac implementation note:* the private key is generated in-place in the Keychain (`SecKeyCreateRandomKey`, `isPermanent`), the cert is signed through that `SecKey` (swift-certificates `Certificate.PrivateKey(_ secKey:)`), and a `SecIdentity` is recovered with `SecIdentityCreateWithCertificate` → `sec_identity_t`. No private API. A Rust client just keeps a PEM/DER key+cert on disk.

## Transport — TLS 1.3, mutual auth

Wrap the TCP connection in **TLS 1.3 (min = max = 1.3)**. Both peers present their device certificate (**mutual authentication** — the Display requests a client cert):

- Mac: `NWProtocolTLS` with `sec_protocol_options_set_local_identity`, `set_min/max_tls_protocol_version(.TLSv13)`, `set_peer_authentication_required(true)`, and a **verify block that accepts any certificate** (`complete(true)`). There is no CA/hostname to check; trust is established at the app layer. Without a verify block Network.framework would reject the self-signed cert by default.
- Rust: `rustls` with a **custom `ServerCertVerifier`/`ClientCertVerifier`** that returns `Ok` unconditionally (danger accepted — the PIN proof + pin are the real gate), or OpenSSL with `SSL_VERIFY_PEER` + a verify callback that always returns 1. Client must present its own cert (`set_certificate`/`set_private_key`).

Any cipher suite TLS 1.3 negotiates is fine (all provide forward secrecy). Renegotiation does not exist in 1.3.

### Public-key pinning ("keyChanged")

After the handshake, each side reads the peer's **leaf certificate** and computes its `spkiHash` and `deviceId` (Mac: from the connection's TLS metadata via `sec_protocol_metadata_access_peer_certificate_chain`, uniformly on both accepted and dialed sides).

- The **dialing** side (Source), when it dials a peer it has **already pinned** (it knows the expected `deviceId`, e.g. from the Bonjour `did` TXT record or the last host), **requires** the presented leaf's derived `deviceId` to equal the expected one. Mismatch → **fail the connection immediately, before any app data**, close reason **`keyChanged`** (fatal; UI: "This Mac's identity changed — re-pair to trust it again."). This catches a MITM presenting a substituted cert or a reinstalled peer.
- A first-time (unpinned) connection accepts any key; identity is then established by the PIN proof.

## Pairing — CPace PAKE (before HELLO)

The **Display** shows a 6-digit PIN (rotatable; only affects future pairings). On a **first-time** connection (neither side has the peer pinned), after TLS is ready and **before** HELLO, both sides run **CPace** — a balanced PAKE — over the established TLS channel, keyed by the shared PIN and bound to *this specific TLS channel*. CPace has the property that a wrong PIN yields an **unrelated** shared secret: the attacker learns nothing offline-crackable, so each guess costs one online, rate-limited interaction. An active MITM terminating TLS toward the Source sees a different pair of leaf certificates, so its channel binding (used as the CPace channel identifier `CI`) differs and it cannot complete the exchange with either honest endpoint.

### Ciphersuite

**`CPACE-X25519-SHA512-ELLIGATOR2`** per **`draft-irtf-cfrg-cpace-21`** (April 2026), the CFRG balanced PAKE. Chosen because (a) balanced fits "both sides hold the PIN at pairing time", and (b) it needs only X25519 Diffie-Hellman — no elliptic-curve point addition — so the Mac side uses swift-crypto's `Curve25519.KeyAgreement` for all scalar·point work; the only custom primitive is the Elligator2 map-to-curve. Group `G_X25519`: `DSI = "CPace255"`, `DSI_ISK = "CPace255_ISK"`, identity `I = 0³²`. Hash `SHA-512`, input block size `s_in_bytes = 128`.

### Channel binding (the CPace `CI`)

Let `clientSPKI` and `serverSPKI` be the 32-byte `spkiHash` of the **client** (dialing Source) and **server** (listening Display) leaf certs.

```
channelBinding = SHA-256( clientSPKI[32] ‖ serverSPKI[32] )        // 32 bytes  → CPace CI
```

Order is always client-then-server, independent of who computes it. Both sides know their own role and both SPKIs (own + peer, from the handshake), so both derive the same value. Using it as the CPace `CI` is what binds the PAKE to this exact TLS channel — a relay MITM has a different `channelBinding` and its generator diverges from the honest one.

> **Why cert-hash binding and not TLS exporter keying material (EKM)?** RFC 8446 EKM (`tls-exporter`) was the design target, but Network.framework does not reliably expose the exporter via public API at a point where *both* peers can run the exchange (`sec_protocol_metadata_create_secret` inside the verify block returns inconsistent/`nil` results; there is no supported post-handshake metadata accessor on `NWConnection`). Channel binding over both leaf SPKIs is captured reliably and, as the CPace `CI`, binds the PAKE to the channel. **A Rust client must use this cert-hash binding**, not EKM. (If EKM interop is ever added it will be a protocol-minor bump with a negotiated flag.)

### CPace parameters (byte-exact)

```
PRS  = utf8(PIN)                              // the low-entropy password (6 ASCII digits)
CI   = channelBinding                         // 32 bytes, above
sid  = SHA-256(channelBinding)                // 32 bytes; deterministic — no sid exchange
ADa  = ADb = "" (empty)                       // deviceIds are already bound through CI
```

- Roles: the **Source is the CPace initiator (A)**, the **Display is the responder (B)** — the Source always sends its share first (it leads pairing; see [Exchange](#exchange)).
- `sid` is deterministic because both peers already share `channelBinding`; per-run key freshness comes from the fresh random scalars, not from `sid`. (`sid` reuse across reconnects between the same pair is harmless here — fresh scalars make every `Ya/Yb/K/ISK` independent.)

**Generator** `g = calculate_generator(H, PRS, CI, sid)` (draft §8.1/§8.2):

```
gen_str  = lv_cat(DSI, PRS, zero_bytes(len_zpad), CI, sid)         // len_zpad fills the 1st SHA-512 block
u        = decodeUCoordinate( SHA-512(gen_str)[0:32], 255 )        // first 32 bytes; clear bit #255
g        = map_to_curve_elligator2(u)                              // Curve25519 u-coordinate, 32 bytes
```

where `lv_cat` prepends each field's LEB128 length (`prepend_len`), and `len_zpad = max(0, 128 − len(prepend_len(PRS)) − len(prepend_len(DSI)) − 1)`. Elligator2 uses `A = 486662`, `B = 1`, non-square `Z = 2`.

**Shares, shared secret, session key**:

```
ya, yb   = 32 random bytes each          // sample_scalar; X25519 clamps internally
Ya = X25519(ya, g)                        // Source share  (PAIR_MSG)
Yb = X25519(yb, g)                        // Display share (PAIR_MSG)
K  = X25519(ya, Yb) = X25519(yb, Ya)      // MUST abort (BYE "auth") if K == 0³² (low-order point)
ISK = SHA-512( lv_cat("CPace255_ISK", sid, K) ‖ lv_cat(Ya, ADa) ‖ lv_cat(Yb, ADb) )   // 64 bytes, initiator-first
```

**Key confirmation** (draft §10.4 — this is the message where a wrong PIN fails):

```
mac_key = SHA-512( "CPaceMac" ‖ sid ‖ ISK )                    // 64 bytes
Ta = HMAC-SHA-512( mac_key, lv_cat(Ya, ADa) )                  // Source's tag  (PAIR_CONFIRM)
Tb = HMAC-SHA-512( mac_key, lv_cat(Yb, ADb) )                  // Display's tag (PAIR_CONFIRM)
```

The Source sends its tag first; the **Display withholds its tag until the Source's verifies** (see the exchange — this is a security requirement, not just an ordering choice). Tags are compared **constant-time**. A mismatch (wrong PIN, or mismatched channel) → `BYE("auth")`.

### Exchange

Message types (see [02](02-protocol.md)): `PAIR_MSG = 0x04` (payload = 32-byte CPace share), `PAIR_CONFIRM = 0x05` (payload = 64-byte HMAC-SHA512 tag). CPace runs on an unpaired connection; a **paired reconnect skips it entirely** (no `0x04`/`0x05` on the wire) and goes straight to HELLO.

```
Source (initiator A)                       Display (responder B)
  │ ── PAIR_MSG(Ya) ────────────────────────▶ │  rate-limit gate; compute g, yb, Yb
  │                                            │  K = X25519(yb, Ya)  (abort→BYE"auth" if 0)
  │ ◀──────────────────────── PAIR_MSG(Yb) ─── │  derive ISK, mac_key; withhold Tb
  │ K = X25519(ya, Yb) (abort→BYE"auth" if 0)  │
  │ derive ISK, mac_key                        │
  │ ── PAIR_CONFIRM(Ta) ────────────────────▶ │  verify Ta constant-time
  │                                            │   ├ fail → record failure; BYE("auth")
  │ ◀──────────────────── PAIR_CONFIRM(Tb) ─── │   └ ok   → reset limiter; PIN Source; send Tb
  │ verify Tb constant-time                    │
  │   ├ fail → BYE("auth")                      │
  │   └ ok   → PIN the Display                  │
  │            (both proceed to HELLO)          │
```

**Why the Display withholds `Tb` until `Ta` verifies (security-critical).** `Ta`/`Tb` are HMACs of a `mac_key` derived from the shared secret; either tag lets an attacker who supplied a *guess* share check the guess offline (does the tag match the value it predicts for its guessed PIN?). If the Display sent `Tb` immediately, an attacker could send one guess share, harvest `Tb`, check the guess, and disconnect **without sending `Ta`** — never tripping the rate limiter, which only charges a *received* wrong tag. By withholding `Tb`, every guess must arrive as a `Ta` the Display verifies-and-charges, so the 5-failure lockout genuinely bounds online guessing. (A conformant implementation MUST NOT reveal its confirmation tag before verifying the peer's.)

On mutual confirmation success **both sides pin the peer** (`deviceId → {spkiHash, name, pairedAt}`) and then run the normal HELLO handshake ([02](02-protocol.md)). The name is filled in from the peer's HELLO `deviceName` once it arrives (it was unknown at pin time). Any confirmation/abort failure → **`BYE{reason:"auth"}`** + close (fatal-for-reconnect; the Source UI shows "PIN incorrect"). A BYE is flushed before the socket is torn down so the peer receives the reason rather than a bare reset.

Rules:
- **The PIN never crosses the wire**: only CPace public shares (`Ya`/`Yb`) and the key-confirmation MACs travel. A wrong PIN produces an unrelated `ISK`, so confirmation fails and nothing offline-crackable is exposed — each guess costs one online, rate-limited attempt.
- Reject the identity element: if `K == 0³²` (peer sent a low-order point), abort. swift-crypto's X25519 already throws for this; Sidewire also checks the all-zero result explicitly.
- A PIN is short-lived and rotatable; rotation only changes the code required for **future** pairings.

### Rust interop notes

A Rust Display client must implement the identical CPace ciphersuite to pair with the Mac:
- Crate: **`cpace`** (or hand-rolled) over **`curve25519-dalek`**; the map is `curve25519-dalek`'s `MontgomeryPoint` Elligator (or RFC 9380 `map_to_curve_elligator2` for curve25519) — verify against the draft's generator test vector.
- Ciphersuite string: `CPACE-X25519-SHA512-ELLIGATOR2`, `DSI = "CPace255"`, `DSI_ISK = "CPace255_ISK"`, SHA-512, `s_in_bytes = 128`.
- Bind `PRS = utf8(PIN)`, `CI = channelBinding`, `sid = SHA-256(channelBinding)`, `ADa = ADb = ""`; **initiator-responder** transcript ordering (`transcript_ir`), Source = initiator.
- Key confirmation exactly as above (`mac_key = SHA-512("CPaceMac" ‖ sid ‖ ISK)`, `HMAC-SHA-512` over `lv_cat(share, AD)`), constant-time compare.
- Conformance material: `protocol-vectors/pairing-vectors.json` (deterministic — fixed PIN + fixed SPKIs + injected scalars → expected `g`, shares, `K`, `ISK`, `mac_key`, tags). The Mac's implementation is verified byte-for-byte against the draft's own published X25519/SHA-512 vectors.

## Rate limiting (Display / server side)

The Display bounds online guessing of the 6-digit PIN. In-memory (a relaunch clears it — acceptable):

- Track **consecutive failed pairings** (a failed key confirmation, or a `K` abort). After **5** consecutive failures, impose a **lockout**: while locked, a new pairing attempt is refused **immediately** on the first `PAIR_MSG` with **`BYE{reason:"rateLimited"}`** (fatal; UI: "Too many wrong PIN attempts — wait a minute and try again.") — CPace is not even run.
- Lockout duration starts at **60 s** and **doubles** on each repeated lockout (60 → 120 → 240 …), capped at **15 min**.
- A **successful** pairing resets the failure count and lockout state.

## Trust store

Keyed by peer `deviceId`; stores `{ spkiHash (hex), name, pairedAt (unix seconds) }`. Mac: Keychain `kSecClassGenericPassword`, service `com.kinocoder.sidewire.trust`, account = `deviceId`, value = JSON, fronted by an in-memory cache. API: `peers()`, `pinned(for:)`, `pin(_)`, `forget(_)`.

- On a paired reconnect, both sides find the peer by `deviceId` (derived from the presented key) and **skip CPace**; the presented key necessarily matches the pin because `deviceId = first16(spkiHash)`.
- Surfaced in Settings as **"Paired Macs"** with a **Forget** action per row (revokes trust; the next connection re-pairs). If one side forgets but the other doesn't, the mismatch surfaces as a `BYE("auth")`; the Source then drops its stale pin so the next manual connect re-pairs cleanly.

## Input-injection gate

A session only reaches streaming **after** pairing (a fresh CPace run with mutual key confirmation) or a pinned-key reconnect, so "streaming ⇒ the peer is trusted" — the control channel is never driven by an unpaired peer. (`InputInjector` remains gated on Accessibility; the pairing gate is upstream of it.)

## Close reasons (fatal-for-reconnect)

`auth` (wrong PIN), `keyChanged` (pinned peer presented a different key), `rateLimited` (locked out), plus the existing `user`, `protocol`, `role`, `error`, `superseded`. All are in `Reconnector.fatalReasons` — the Source stops and surfaces a human message rather than looping.

## What this is not

No accounts, no cloud, no relay server, no telemetry. Everything is local and peer-to-peer.

**Resistant to an active on-path attacker at pairing time (Phase 7c).** CPace, bound to the TLS channel via `CI = channelBinding`, makes each PIN guess cost one **online** interaction: a wrong PIN produces an unrelated CPace shared secret and the key-confirmation MAC fails, exposing nothing offline-crackable; the Display's rate limiter bounds the online guesses. This closes the gap the Phase-7a HMAC proof left open (that proof stopped *relay* but not *offline guessing*). Still out of scope, as before: a compromised endpoint, physical access, and nation-state traffic analysis.
