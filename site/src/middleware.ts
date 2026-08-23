import { defineMiddleware } from 'astro:middleware';
import { GenerationTracker, isCacheableRequest, serveVersionedPage } from './lib/cache.ts';
import { exportGeneratedAt } from './lib/d1.ts';
import { getDb } from './lib/db.ts';

// Cloudflare applies public/_headers only to static assets, but every rakkan
// route is SSR, so responses would ship without these headers. Set-if-absent
// lets a route opt out. style-src keeps 'unsafe-inline' because the progress
// and trend bars set width via style attributes; img-src allows data: for the
// inline SVG favicon. No scripts ship at all, but script-src 'self' leaves
// room for a future bundled script without a policy change.
const SECURITY_HEADERS: Record<string, string> = {
  'X-Frame-Options': 'DENY',
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'strict-origin-when-cross-origin',
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
  'Strict-Transport-Security': 'max-age=63072000; includeSubDomains; preload',
  'X-XSS-Protection': '0',
  'Cross-Origin-Embedder-Policy': 'credentialless',
  'Cross-Origin-Opener-Policy': 'same-origin',
  'Cross-Origin-Resource-Policy': 'same-origin',
  'Content-Security-Policy':
    "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
};

// The heavy read-only pages (overview, 1,000-row index, per-package version
// history, sitemap) are edge-cached by export generation. Cacheable requests
// read the one-row generation marker; only misses run the heavier page queries.
// Search (query string) and anything non-GET stay uncached. The Cache API is
// absent in plain node contexts, so those contexts degrade to pass-through.

function edgeCache(): Cache | undefined {
  // Dev serves fresh renders (the Cloudflare Vite plugin has a working Cache API,
  // which would otherwise pin stale pages across edits).
  if (!import.meta.env.PROD) return undefined;
  return (globalThis as { caches?: { default?: Cache } }).caches?.default;
}

// A warm isolate can keep serving its last edge generation through a transient
// D1 lookup failure. A cold isolate has no generation to guess from.
const generationTracker = new GenerationTracker();

export const onRequest = defineMiddleware(async (context, next) => {
  const cacheable = isCacheableRequest(context.request.method, context.request.url);
  const cache = cacheable ? edgeCache() : undefined;

  const render = async () => {
    const response = await next();

    for (const [name, value] of Object.entries(SECURITY_HEADERS)) {
      if (!response.headers.has(name)) {
        response.headers.set(name, value);
      }
    }

    return response;
  };

  if (!cache) return render();

  const generatedAt = await generationTracker.current(() => exportGeneratedAt(getDb()));
  return serveVersionedPage(cache, context.request.url, generatedAt, render);
});
