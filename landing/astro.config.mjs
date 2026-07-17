// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// Static output (the default). `astro build` emits a fully static site into dist/, which the
// container image serves with nginx (see Dockerfile). `site` feeds canonical URLs + the sitemap —
// set it to the real production origin before shipping.
export default defineConfig({
  site: 'https://sidewire.app',
  integrations: [sitemap()],
});
