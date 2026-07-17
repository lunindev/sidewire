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
  data/site.ts          all copy (features, steps, specs, FAQ) — typed
  layouts/Base.astro    <head>, SEO/OG meta, global styles
  components/*.astro     Nav, Hero, WireDiagram, Features, HowItWorks, CrossPlatform, TechBand, Faq, CTA, Footer
  pages/index.astro      composes the page
  pages/404.astro        not-found page
  styles/global.css      design tokens + shared primitives
public/                  favicon.svg, og.svg, robots.txt
```

## Build & check

```bash
pnpm build          # → dist/  (static)
pnpm preview        # serve the built dist/ locally
pnpm check          # astro check (TypeScript / template diagnostics)
```

## Container (what CI ships)

The GitLab pipeline (`.gitlab-ci.yml` at the repo root) builds the `landing-prod` target on every
git tag and pushes it to the registry:

```bash
# from the repo root
docker build --target landing-prod -f landing/Dockerfile -t sidewire-landing landing
docker run --rm -p 8080:80 sidewire-landing   # → http://localhost:8080
```

## Before going live

- Set the production origin in [`astro.config.mjs`](astro.config.mjs) (`site`) — it feeds canonical
  URLs and the sitemap.
- The GitHub / download URLs in [`src/data/site.ts`](src/data/site.ts) (`links`) point at
  `github.com/lunindev/sidewire` and its latest release — update if the repo moves.

## Versioning

Don't bump the version here by hand. `pnpm version:patch|minor|major` at the **repo root** bumps
this `package.json`, the root one, and the native app's `MARKETING_VERSION` together, then tags
`vX.Y.Z` — which is what triggers the landing image build.
