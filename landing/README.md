# Sidewire — landing site

The marketing page for Sidewire, built with **Astro + TypeScript** and shipped as a static site
served by nginx in a container.

## Develop

```bash
pnpm install        # from this folder (landing/)
pnpm dev            # http://localhost:4321
```

All copy lives in one typed file — [`src/data/site.ts`](src/data/site.ts). Edit text there; the
components in `src/components/` are presentational and read from it.

```
src/
  data/site.ts           all copy (links, nav, features, steps, specs, FAQ) — typed
  layouts/Base.astro     <head>, SEO/OG meta, skip link, global styles, named "head" slot
  components/*.astro     Nav, Hero, WireDiagram, Features, HowItWorks, CrossPlatform, TechBand,
                         Faq, CTA, Footer, StructuredData
  pages/index.astro      composes the page
  pages/privacy.astro    privacy policy
  pages/terms.astro      terms of use
  pages/404.astro        not-found page
  styles/global.css      design tokens + shared primitives
public/                  favicon.svg, og.png, robots.txt
```

The site ships **zero JavaScript** and makes **zero external requests** — no web fonts, no CDN, no
analytics, all icons inline SVG. That is deliberate: it is what lets `nginx.conf` serve a
`default-src 'none'` CSP, and it is what the privacy page claims. Keep it that way.

`StructuredData.astro` emits the JSON-LD (`FAQPage` + `SoftwareApplication`) and generates it from
`src/data/site.ts`, so the structured data cannot drift from the visible copy. It is a
`<script type="application/ld+json">` block, which browsers never execute — that is why the CSP can
still say `script-src 'none'`.

## Build & check

```bash
pnpm build          # → dist/  (static)
pnpm preview        # serve the built dist/ locally
pnpm check          # astro check (TypeScript / template diagnostics)
```

## Container (what CI ships)

There is no pipeline; build the `landing-prod` target by hand on every
git tag and pushes it to the registry:

```bash
# from the repo root
docker build --target landing-prod -f landing/Dockerfile -t sidewire-landing landing
docker run --rm -p 8080:8080 sidewire-landing   # → http://localhost:8080
```

The serve stage is [`nginxinc/nginx-unprivileged`](https://hub.docker.com/r/nginxinc/nginx-unprivileged),
so **no process in the container runs as root** — which is why nginx listens on **8080** rather than
80 (a non-root process cannot bind a privileged port). If you put this behind a proxy or an
orchestrator, target container port `8080`.

Check the headers after a change:

```bash
curl -sI http://localhost:8080/ | grep -iE 'server|content-security|permissions|x-|referrer'

# The /_astro/ block defines its own add_header, which RESETS inheritance — so the same headers
# have to be repeated there. Check a real hashed asset, not the directory (that 404s):
asset=$(ls dist/_astro | head -1)
curl -sI "http://localhost:8080/_astro/$asset" | grep -iE 'content-security|permissions|x-|referrer'
```

## Before going live

- Set the production origin in [`astro.config.mjs`](astro.config.mjs) (`site`) — it feeds canonical
  URLs and the sitemap.
- The GitHub / download / licence URLs in [`src/data/site.ts`](src/data/site.ts) (`links`) point at
  `github.com/lunindev/sidewire` — update if the repo moves.
- **Copy is written for a pre-release product.** There is no published build, and no Windows or
  Linux binary has ever been produced, so the CTAs say "Watch for the v1 release" and the
  cross-platform section is marked "Coming next". When a signed release actually exists, that
  wording — in `site.ts`, `Hero.astro`, `CTA.astro`, `HowItWorks.astro` and `CrossPlatform.astro` —
  is what changes.
- The [privacy page](src/pages/privacy.astro) makes checkable claims about the app's network
  behaviour (opt-in Sparkle update check, nothing else). Re-verify them against
  `app/Sidewire/Resources/Info.plist` before any release that touches networking.

## Versioning

Don't bump the version here by hand. `pnpm version:patch|minor|major` at the **repo root** bumps
this `package.json`, the root one, and the native app's `MARKETING_VERSION` together, then tags
`vX.Y.Z` — which is what triggers the landing image build.
