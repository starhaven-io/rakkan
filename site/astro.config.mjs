// @ts-check
import cloudflare from '@astrojs/cloudflare';
import { defineConfig } from 'astro/config';

// https://astro.build/config
export default defineConfig({
  site: 'https://rakkan.dev',
  // No sessions: without this the adapter emits a SESSION KV binding into
  // the generated deploy config for a namespace that does not exist.
  session: false,
  // Never inline bundled scripts into the HTML: script-src carries no
  // 'unsafe-inline', so an inlined script (anything under the default 4 KB
  // limit) would be CSP-blocked. External /_astro/*.js is also cached immutable.
  vite: { build: { assetsInlineLimit: 0 } },
  adapter: cloudflare({
    imageService: 'passthrough',
  }),
});
