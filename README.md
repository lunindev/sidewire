# Sidewire

**Give your main Mac a second screen — using a Mac you already own.** Sidewire turns a spare Mac
into a real extra display for your primary one, over a direct Thunderbolt cable or over Wi‑Fi. Not
screen sharing — an actual desktop you drag windows onto, with your keyboard and mouse working
across both machines.

This repository is a small monorepo:

```
app/        the product — native macOS app (SwiftUI, Universal 2) + a Rust Windows/Linux client
landing/    the marketing site — Astro + TypeScript, static, containerised for GitLab CI
scripts/    release tooling shared by both (version bump + changelog + tag)
```

- **[app/README.md](app/README.md)** — everything about the native app: architecture, how to build
  the macOS app and the Rust client, distribution/notarization, and Sparkle auto‑update.
- **[landing/README.md](landing/README.md)** — the landing site: develop, build, and the container
  image the pipeline publishes.
- **[TODO.md](TODO.md)** — the honest, prioritised list of what is left before this can be released.

## Status — pre-release

**Code-complete and test-covered, but not yet run on physical hardware, and not yet releasable.**

- **Verified:** 40 + 39 Swift tests, 80 Rust tests, and a byte-exact protocol conformance suite
  ([`app/protocol-vectors/`](app/protocol-vectors/)) that the Swift and Rust implementations
  reproduce independently.
- **Not verified:** no build has run on two physical Macs, live Rust↔Swift interop has never been
  exercised, and no Windows or Linux binary has ever been produced.
- **Not ready:** there is no CI, no tagged release, no notarized build, and the checked-in signing
  configuration does not resolve on a fresh clone. [`TODO.md`](TODO.md) tracks all of it.

Requirements: macOS 14+ on both Macs, plus Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
to build from source.

## Versioning & releases

One version drives everything. From the repo root:

```bash
pnpm version:dry            # preview the next release (no changes)
pnpm version:patch          # x.y.Z  → bump + changelog + commit + tag vX.Y.Z
pnpm version:minor          # x.Y.0
pnpm version:major          # X.0.0
pnpm release:undo           # unwind the last release commit + tag (only before pushing)
```

Each bump updates, in lockstep:

- `package.json` (root) and `landing/package.json` — the web/semver version,
- `app/project.yml` — the native app's `MARKETING_VERSION` (and its integer build number), which
  `app/scripts/release.sh` reads as the single source of truth for the DMG + Sparkle appcast,

then writes a section to [`CHANGELOG.md`](CHANGELOG.md) from your Conventional Commits, commits, and
tags `vX.Y.Z`.

> **This flow has never been run.** There are no tags yet, so the first bump would write a changelog
> section spanning the entire history, and [`.gitlab-ci.yml`](.gitlab-ci.yml) — which is gated on
> tags and pinned to a self-hosted runner — has never fired. The native macOS app is not built by
> any pipeline: it needs Apple signing/notarization and is built by hand with
> `app/scripts/release.sh`. See [`TODO.md`](TODO.md).

## License

[MIT](LICENSE)
