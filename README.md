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
  image CI publishes.

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
tags `vX.Y.Z`. Pushing that tag (`git push --follow-tags`) triggers GitLab CI, which builds the
landing container image and publishes it to the registry (see [`.gitlab-ci.yml`](.gitlab-ci.yml)).

> The native macOS app is **not** built by GitLab — it needs Apple signing/notarization and is built
> by GitHub Actions ([`.github/workflows/`](.github/workflows)) and `app/scripts/release.sh`.

## License

[MIT](LICENSE)
