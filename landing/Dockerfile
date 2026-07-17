# syntax=docker/dockerfile:1
# Sidewire landing — build the static Astro site, then serve it with nginx.
# Build context is landing/ (see .gitlab-ci.yml: `docker build ... landing`).
# The GitLab job builds `--target landing-prod`.

# ── build stage ──────────────────────────────────────────────────────────────
FROM node:22-alpine AS build
WORKDIR /app

# Corepack activates the pnpm version pinned in package.json ("packageManager").
RUN corepack enable

# Install deps first (cached until the manifest/lockfile change). pnpm-workspace.yaml carries the
# build-script approvals (esbuild/sharp), so it must be present for the postinstalls to run here.
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile

# Build the static site.
COPY . .
RUN pnpm build

# ── serve stage ──────────────────────────────────────────────────────────────
FROM nginx:1.27-alpine AS landing-prod
# Replace the default server block with our static-site config.
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD wget -qO- http://127.0.0.1/ >/dev/null 2>&1 || exit 1
CMD ["nginx", "-g", "daemon off;"]
