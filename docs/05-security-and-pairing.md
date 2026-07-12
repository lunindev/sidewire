# 05 — Security & Pairing (protocol v2)

Implemented in Phase 7a (protocol v2). Read [00 D6](00-review-and-decisions.md) and [09 §D11](09-next-stage.md) for the decisions. The threat this closes is specific and serious: because the Display forwards input that the Source injects with `CGEvent`, **an unauthenticated peer on the LAN gets remote *control* of the primary Mac**, not just a view of it. So this is not "encrypt the video" — it's "don't hand a stranger my keyboard."

This document is **normative for the wire** and precise enough to implement a non-Mac (Rust) client. Everything here is portable — no Apple-specific crypto is on the wire; the Apple-specific parts (Keychain, `SecIdentity`, Network.framework) are implementation notes for the Mac side only.

> **What changed from v1.** v1 used TLS **1.2** with a plain external PSK derived from the PIN (`TLS_PSK_WITH_AES_128_GCM_SHA256`) — no forward secrecy, offline-brute-forceable from a passive capture, no trust store, no rate limiting. v2 replaces it with **certificate-based TLS 1.3 + a channel-bound PIN proof + a Keychain trust store**. Nothing shipped on v1, so there is no dual-stack: a v1 peer is rejected at HELLO (`protocol.major` bumped to **2**).

## Threat model

In scope (must defend):
- A rogue device on the same LAN/Wi-Fi connecting to a Source and injecting input **without the PIN**.
- A passive eavesdropper on the LAN reading screen contents (now also forward-secret).
- A **passive** attacker or an **off-path** attacker during pairing: cannot recover the PIN or impersonate a peer.

Partially defended (known residual risk — see [§ What this is not](#what-this-is-not)):
- An **active MITM that terminates TLS toward the Source at pairing time** cannot *relay* a proof (the channel binding stops that), but it CAN offline-brute-force the 6-digit PIN from the Source's first proof, because the proof is an HMAC of `HKDF(PIN, channelBinding)` and the MITM knows its own `channelBinding`. A 6-digit PIN has ~20 bits of entropy — crackable in well under a second. **The robust fix is a PAKE (SPAKE2+/CPace); it is deliberately deferred** (docs/09 open question), and this residual risk is acceptable only for a trusted LAN / Thunderbolt link. Do not represent Sidewire as safe against an on-path attacker during pairing until a PAKE lands.

Out of scope (v1/v2, acceptable): a compromised endpoint; nation-state traffic analysis; physical access to either Mac; an active on-path attacker during the pairing handshake (see above).

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

## Pairing — channel-bound PIN proof (before HELLO)

The **Display** shows a 6-digit PIN (rotatable; only affects future pairings). On a **first-time** connection (neither side has the peer pinned), after TLS is ready and **before** HELLO, both sides run a mutual proof that binds the shared PIN to *this specific TLS channel*. An active MITM terminating TLS sees a different pair of leaf certificates than the honest endpoints, so its channel-binding value differs and it **cannot relay a captured proof** to the other side. It can, however, offline-guess the low-entropy PIN from a proof captured on its own channel (see the threat model's residual-risk note) — the channel binding defeats relay, not offline guessing of a weak secret. A PAKE would close that gap.

### Channel binding

Let `clientSPKI` and `serverSPKI` be the 32-byte `spkiHash` of the **client** (dialing Source) and **server** (listening Display) leaf certs.

```
channelBinding = SHA-256( clientSPKI[32] ‖ serverSPKI[32] )        // 32 bytes
```

Order is always client-then-server, independent of who computes it. Both sides know their own role and both SPKIs (own + peer, from the handshake), so both derive the same value.

> **Why cert-hash binding and not TLS exporter keying material (EKM)?** RFC 8446 EKM (`tls-exporter`) was the design target, but Network.framework does not reliably expose the exporter via public API at a point where *both* peers can run the proof: `sec_protocol_metadata_create_secret` inside the verify block (which runs mid-handshake) returns inconsistent/`nil` results, and there is no supported post-handshake metadata accessor on `NWConnection`. Channel binding over both leaf SPKIs is captured reliably and, like EKM, prevents a MITM from *relaying* a proof between channels (it does not, on its own, protect a low-entropy PIN from offline guessing — a PAKE is what would). **A Rust client interoperating with the Mac must use this cert-hash binding**, not EKM. (If EKM interop is ever added it will be a protocol-minor bump with a negotiated flag.)

### Key + proofs (byte-exact)

```
K           = HKDF-SHA256( IKM  = utf8(PIN),
                           salt = "sidewire-pairing-v2",     // 19 ASCII bytes, no NUL
                           info = channelBinding,            // the 32 bytes above
                           L    = 32 )
clientProof = HMAC-SHA256( K, "sidewire-client-proof" )      // 32 bytes  (Source proves)
serverProof = HMAC-SHA256( K, "sidewire-server-proof" )      // 32 bytes  (Display proves)
```

The HMAC message is the literal ASCII label (21 bytes, no NUL). The `deviceId` is `first16(SPKI)` and thus already bound into the proof through the channel binding, so it needs no separate HMAC input. Proof comparisons MUST be constant-time.

### Exchange

New message types (see [02](02-protocol.md)): `PAIR_PROOF = 0x04` (payload = 32-byte HMAC), `PAIR_ACK = 0x05` (empty). The proof runs on an unpaired connection; a **paired reconnect skips it entirely** (no `0x04`/`0x05` on the wire) and goes straight to HELLO.

```
Source (client)                         Display (server)
  │ ── PAIR_PROOF(clientProof) ───────────▶ │  verify clientProof with own K
  │                                          │   ├ fail → record failure; BYE("auth"); close
  │                                          │   └ ok   → reset rate limiter; PIN the Source;
  │ ◀───────────── PAIR_PROOF(serverProof) ─ │           reply serverProof
  │ verify serverProof with own K            │
  │   ├ fail → BYE("auth"); close            │
  │   └ ok   → PIN the Display;              │
  │ ── PAIR_ACK ──────────────────────────▶ │  proceed to application handshake
  │            (both proceed to HELLO)       │
```

On mutual success **both sides pin the peer** (`deviceId → {spkiHash, name, pairedAt}`) and then run the normal HELLO handshake ([02](02-protocol.md)). The name is filled in from the peer's HELLO `deviceName` once it arrives (it was unknown at pin time). Any proof failure → **`BYE{reason:"auth"}`** + close (fatal-for-reconnect; the Source UI shows "PIN incorrect"). A BYE is flushed before the socket is torn down so the peer receives the reason rather than a bare reset.

Rules:
- **The PIN never crosses the wire**: only HMACs keyed by `HKDF(PIN, channelBinding)` travel, and the channel binding prevents a MITM from relaying those HMACs between channels. Caveat (do not overclaim): a proof captured on the attacker's *own* channel is offline-guessable against the 6-digit PIN — a passive/off-path attacker never obtains such a capture, but an active on-path attacker at pairing time does (see the threat model). This is the gap a PAKE would close.
- A PIN is short-lived and rotatable; rotation only changes the code required for **future** pairings.

## Rate limiting (Display / server side)

The Display bounds online guessing of the 6-digit PIN. In-memory (a relaunch clears it — acceptable):

- Track **consecutive failed proofs**. After **5** consecutive failures, impose a **lockout**: while locked, a new pairing attempt is refused **immediately** with **`BYE{reason:"rateLimited"}`** (fatal; UI: "Too many wrong PIN attempts — wait a minute and try again.") — the proof is not even evaluated.
- Lockout duration starts at **60 s** and **doubles** on each repeated lockout (60 → 120 → 240 …), capped at **15 min**.
- A **successful** proof resets the failure count and lockout state.

## Trust store

Keyed by peer `deviceId`; stores `{ spkiHash (hex), name, pairedAt (unix seconds) }`. Mac: Keychain `kSecClassGenericPassword`, service `com.kinocoder.sidewire.trust`, account = `deviceId`, value = JSON, fronted by an in-memory cache. API: `peers()`, `pinned(for:)`, `pin(_)`, `forget(_)`.

- On a paired reconnect, both sides find the peer by `deviceId` (derived from the presented key) and **skip the proof**; the presented key necessarily matches the pin because `deviceId = first16(spkiHash)`.
- Surfaced in Settings as **"Paired Macs"** with a **Forget** action per row (revokes trust; the next connection re-pairs). If one side forgets but the other doesn't, the mismatch surfaces as a `BYE("auth")`; the Source then drops its stale pin so the next manual connect re-pairs cleanly.

## Input-injection gate

A session only reaches streaming **after** pairing (fresh proof) or a pinned-key reconnect, so "streaming ⇒ the peer is trusted" — the control channel is never driven by an unpaired peer. (`InputInjector` remains gated on Accessibility; the pairing gate is upstream of it.)

## Close reasons (fatal-for-reconnect)

`auth` (wrong PIN), `keyChanged` (pinned peer presented a different key), `rateLimited` (locked out), plus the existing `user`, `protocol`, `role`, `error`, `superseded`. All are in `Reconnector.fatalReasons` — the Source stops and surfaces a human message rather than looping.

## What this is not

No accounts, no cloud, no relay server, no telemetry. Everything is local and peer-to-peer.

**Not (yet) resistant to an active on-path attacker at pairing time.** The channel-bound PIN proof stops proof *relay* but not *offline PIN guessing* by an attacker that terminates TLS toward the Source during pairing (§ Threat model). Closing this needs an augmented **PAKE** (SPAKE2+ or CPace), where each PIN guess costs an online interaction — the same low-entropy PIN then resists offline attack. This is a real crypto undertaking (correct group generators, key confirmation, matching Swift + Rust implementations) and is a **tracked decision for the owner** (docs/09), not a silent TODO. Until it lands, treat first-time pairing as safe on a trusted LAN / Thunderbolt link, not on a hostile network.
