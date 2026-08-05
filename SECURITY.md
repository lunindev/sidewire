# Security Policy

Sidewire hands one machine's keyboard and mouse to another over the network. The Display forwards
input that the Source injects with `CGEvent`, so a peer that gets past pairing gets **remote control
of the primary Mac**, not just a view of it. That is the reason this file exists and the reason the
crypto below is worth your attention.

The project also **hand-rolls primitives** rather than only calling into vetted libraries:

- [`Field25519.swift`](app/Packages/SidewireCore/Sources/SidewireCore/Field25519.swift) — GF(2²⁵⁵−19)
  field arithmetic written for this project.
- [`Elligator2.swift`](app/Packages/SidewireCore/Sources/SidewireCore/Elligator2.swift) — the
  map-to-curve used by the PAKE generator.
- [`CPace.swift`](app/Packages/SidewireCore/Sources/SidewireCore/CPace.swift) — a `CPACE-X25519-SHA512-ELLIGATOR2`
  balanced PAKE per `draft-irtf-cfrg-cpace-21`, channel-bound to a certificate-pinned TLS 1.3 session.

Scalar multiplication is delegated to swift-crypto's `Curve25519.KeyAgreement`, but the field
arithmetic and the map are ours. Constant-time behaviour, low-order-point handling, and the
key-confirmation ordering are all things a reviewer should assume are unverified by anyone but us.

**Read the threat model before reporting:**
[`app/docs/05-security-and-pairing.md`](app/docs/05-security-and-pairing.md). It is normative for
the wire and states explicitly what is in and out of scope for the design.

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Use **GitHub Private Vulnerability Reporting** — the *Report a vulnerability* button on this
repository's **Security** tab. That gives us a private thread, a CVE request path, and a place to
publish an advisory once a fix exists.

> **TODO (repository owner):** add a fallback contact address here for reporters who cannot or will
> not use GitHub — e.g. `security@<domain>` — and confirm Private Vulnerability Reporting is enabled
> under *Settings → Code security and analysis*. This placeholder must be replaced before the
> repository is made public. No address is listed today because none has been decided; do not invent
> one.

Useful things to include: which role each machine had (Source or Display), the transport
(Thunderbolt or Wi-Fi), whether the Rust client was involved, and — for protocol issues — a vector in
the format used by [`app/protocol-vectors/`](app/protocol-vectors/), which is far easier to act on
than prose.

### What to expect

| Stage | Target |
| --- | --- |
| Acknowledgement of your report | 5 business days |
| Initial assessment (in scope? severity? reproducible?) | 14 days |
| Coordinated disclosure window | **90 days** from acknowledgement |

This is a solo, pre-release project, not a funded security team — those are honest targets, not an
SLA. If we go quiet, chase us in the same private thread.

**Coordinated disclosure.** Please give us 90 days before publishing. If a fix lands sooner we will
say so and you are free to publish immediately. If 90 days pass without a fix, publish — we would
rather users know. We will credit you in the advisory unless you ask us not to. There is no bug
bounty.

## Supported versions

**There is no released version.** The repository has no tags, no notarized build, and no published
binary. Anything you find should be reported **against `main`**, and any fix will land on `main`
rather than in a backported release.

| Version | Supported |
| --- | --- |
| `main` (unreleased) | ✅ Report against this |
| Any tagged release | — none exists yet |
| The earlier *MacDisplay* prototype | ❌ Superseded; not this codebase |

This table will be replaced with real version ranges once a release exists.

## In scope

Report anything in these areas:

- **Pairing and the CPace PAKE.** The hand-rolled `Field25519` and `Elligator2` arithmetic, generator
  derivation, low-order-point rejection (`K == 0³²`), constant-time tag comparison, and the rule that
  the Display **must not** reveal its confirmation tag `Tb` before verifying the Source's `Ta` — that
  ordering is what makes the 5-failure lockout actually bound online PIN guessing.
- **TLS channel binding.** `channelBinding = SHA-256(clientSPKI ‖ serverSPKI)` used as the CPace
  `CI`. Any way to make two peers derive the same binding across different TLS channels, or to make
  an honest peer accept a binding it did not participate in, is a break. (Note the deliberate
  decision *not* to use RFC 8446 exporter keying material — the rationale is in docs/05.)
- **The Keychain trust store.**
  [`TrustStore.swift`](app/Packages/SidewireCore/Sources/SidewireCore/TrustStore.swift) — pinning
  `deviceId → spkiHash`, the `keyChanged` detection path, and anything that lets an attacker get a
  pin written, read, or bypassed. `deviceId` is the first 16 bytes of the SPKI hash, so a
  second-preimage or truncation attack on that derivation is in scope.
- **Input-injection gating.** Anything that reaches `InputInjector` — or drives the control channel
  at all — without a completed CPace run or a valid pinned-key reconnect. The gate is documented as
  "streaming ⇒ the peer is trusted"; a counterexample is a serious finding.
- **The private `CGVirtualDisplay` bridge.**
  [`app/Sidewire/Private/`](app/Sidewire/Private/) and `VirtualDisplayManager`, including the
  `--vd-helper` self-re-exec path in `app/Sidewire/App/main.swift`. The app is deliberately
  unsandboxed and re-execs its own binary; argument handling and ancestry there is worth attacking.
- **The wire-protocol parsers.** Every decoder that runs on bytes from a peer, in both
  implementations: [`app/Packages/SidewireProtocol/`](app/Packages/SidewireProtocol/) (frame header,
  `INPUT` records, `VIDEO` sub-header, JSON control messages) and the Rust
  [`sidewire-proto`](app/clients/sidewire-viewer/sidewire-proto/) crate. Length-field handling,
  allocation from attacker-controlled sizes, and anything reachable **before** pairing completes are
  the highest-value targets.

## Out of scope

- **The landing site** ([`landing/`](landing/)) — a static Astro build with no accounts, no forms, no
  analytics and no backend. Missing security headers and the container's nginx hardening are already
  tracked in [`TODO.md`](TODO.md) as ordinary work items, not vulnerabilities.
- **The packaging scaffolding** ([`app/clients/sidewire-viewer/packaging/`](app/clients/sidewire-viewer/packaging/)) —
  every step is currently an `echo "TODO"`. Nothing there has ever produced an artifact, so it has no
  attack surface yet.
- Findings that require a **compromised endpoint**, **physical access** to either Mac, or
  nation-state traffic analysis — explicitly out of scope in the threat model.
- Missing notarization, missing Windows Authenticode signing, and the absence of CI. All known, all
  in `TODO.md`.
- Anything in `node_modules/`, `target/`, or other build output.

## Known weaknesses — please read before reporting

We would rather tell you than have you find these and assume they were hidden. Both are open items in
[`TODO.md`](TODO.md) under *P1 — Security*:

1. **Unauthenticated LAN denial of service.**
   [`TCPListener.swift`](app/Packages/SidewireCore/Sources/SidewireCore/TCPListener.swift) hands the
   connection to `onConnection` at TCP **accept**, and
   [`DisplayController.swift`](app/Sidewire/Roles/Display/DisplayController.swift) immediately closes
   the incumbent session with `.superseded` — before TLS, before CPace. So a bare TCP connect loop
   from anywhere on the LAN tears down a live session repeatedly, with no certificate and no PIN. The
   pairing rate limiter does not help: it is only consulted in `handlePairMsg`. The fix (hold the
   incoming transport aside until it reaches TLS-ready *and* completes CPace, and cap concurrent
   unauthenticated accepts) is specified in `TODO.md`.

2. **A fail-open path in `Session`.**
   [`Session.swift`](app/Packages/SidewireCore/Sources/SidewireCore/Session.swift) guards on
   `pairingConfig` and `tlsPeerInfo` and, if either is `nil`, proceeds to the application handshake —
   skipping CPace and pinning entirely. The only thing keeping it unreachable is a construction
   invariant in `TCPTransport.swift`, and no test asserts that a nil-identity transport is refused.
   It should fail closed; that change and its test are open in `TODO.md`.

Novel exploitation of either — especially anything reaching input injection through path 2 rather
than merely observing it — is still very welcome. A duplicate report of the bare facts above is not
a finding, but it also costs you nothing to send.

Two further caveats that shape any assessment: **nothing has been run on two physical Macs**, and
**live Rust↔Swift interop has never been exercised** — only Rust↔Rust loopback and the byte-exact
golden vectors. Behaviour of the real cross-implementation handshake is genuinely untested.

## Non-security bugs

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.yml). Build and contribution setup
lives in [`CONTRIBUTING.md`](CONTRIBUTING.md).
