import { defineMiddleware } from 'astro:middleware';

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
// history, sitemap) are edge-cached on the data-refresh cadence so anonymous
// traffic cannot ride every request straight to D1. Search (query string)
// and anything non-GET stay uncached. The Cache API is absent in plain node
// contexts, so everything degrades to pass-through outside the Workers
// runtime and its local proxies.
const CACHEABLE_PATH = /^\/$|^\/packages(\/[^/]+)?$|^\/sitemap\.xml$/;
const CACHE_CONTROL = 'public, max-age=300, s-maxage=1800';

function edgeCache(): Cache | undefined {
  // Dev serves fresh renders (the platform proxy has a working Cache API,
  // which would otherwise pin stale pages across edits).
  if (!import.meta.env.PROD) return undefined;
  return (globalThis as { caches?: { default?: Cache } }).caches?.default;
}

export const onRequest = defineMiddleware(async (context, next) => {
  const url = new URL(context.request.url);
  const cacheable =
    context.request.method === 'GET' && url.search === '' && CACHEABLE_PATH.test(url.pathname);
  const cache = cacheable ? edgeCache() : undefined;

  if (cache) {
    const hit = await cache.match(context.request.url);
    if (hit) return hit;
  }

  const response = await next();

  for (const [name, value] of Object.entries(SECURITY_HEADERS)) {
    if (!response.headers.has(name)) {
      response.headers.set(name, value);
    }
  }

  if (cache && response.status === 200) {
    if (!response.headers.has('cache-control')) {
      response.headers.set('cache-control', CACHE_CONTROL);
    }
    await cache.put(context.request.url, response.clone());
  }

  return response;
});
