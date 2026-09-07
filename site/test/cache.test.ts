import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  BROWSER_CACHE_CONTROL,
  EDGE_CACHE_CONTROL,
  GenerationTracker,
  isCacheableRequest,
  markRouteNotFound,
  NOT_FOUND_CACHE_CONTROL,
  serveVersionedPage,
  versionedCacheKey,
  type EdgeCache,
} from '../src/lib/cache.ts';
import { ExportUnavailableError, SchemaVersionError } from '../src/lib/d1.ts';

test('route-owned not-found responses set status and opt out of the generation cache', () => {
  const response = { status: 200, headers: new Headers() };

  markRouteNotFound(response);

  assert.equal(response.status, 404);
  assert.equal(response.headers.get('cache-control'), NOT_FOUND_CACHE_CONTROL);
});

class MemoryCache implements EdgeCache {
  readonly entries = new Map<string, Response>();

  async match(key: string): Promise<Response | undefined> {
    return this.entries.get(key)?.clone();
  }

  async put(key: string, response: Response): Promise<void> {
    this.entries.set(key, response.clone());
  }
}

test('a new data generation bypasses the prior rendered page', async () => {
  const cache = new MemoryCache();
  const url = 'https://rakkan.dev/';
  let renders = 0;
  const render = (body: string) => async () => {
    renders += 1;
    return new Response(body);
  };

  const first = await serveVersionedPage(cache, url, '2026-08-22 06:58:00', render('old'));
  const repeat = await serveVersionedPage(cache, url, '2026-08-22 06:58:00', render('wrong'));
  const refreshed = await serveVersionedPage(cache, url, '2026-08-22 17:28:00', render('new'));

  assert.equal(await first.text(), 'old');
  assert.equal(await repeat.text(), 'old');
  assert.equal(await refreshed.text(), 'new');
  assert.equal(renders, 2);
  assert.equal(first.headers.get('cache-control'), BROWSER_CACHE_CONTROL);
  assert.equal(repeat.headers.get('cache-control'), BROWSER_CACHE_CONTROL);
  assert.equal(refreshed.headers.get('cache-control'), BROWSER_CACHE_CONTROL);
  assert.equal(cache.entries.size, 2);
  assert.equal(
    cache.entries.get(versionedCacheKey(url, '2026-08-22 17:28:00'))?.headers.get('cache-control'),
    EDGE_CACHE_CONTROL,
  );
});

test('attacker-controlled query variants share one rendered cache entry', async () => {
  const cache = new MemoryCache();
  let renders = 0;
  const render = async () => {
    renders += 1;
    return new Response('canonical');
  };

  const first = await serveVersionedPage(
    cache,
    'https://rakkan.dev/packages/rake?nonce=one',
    '2026-08-22 17:28:00',
    render,
  );
  const second = await serveVersionedPage(
    cache,
    'https://rakkan.dev/packages/rake?nonce=two&nonce=three',
    '2026-08-22 17:28:00',
    render,
  );

  assert.equal(await first.text(), 'canonical');
  assert.equal(await second.text(), 'canonical');
  assert.equal(renders, 1);
  assert.equal(cache.entries.size, 1);
  assert.equal(
    versionedCacheKey('https://rakkan.dev/packages/rake?nonce=one', '2026-08-22 17:28:00'),
    versionedCacheKey('https://rakkan.dev/packages/rake?nonce=two', '2026-08-22 17:28:00'),
  );
  assert.equal(
    versionedCacheKey('https://rakkan.dev/packages/rake?page=02&nonce=one', '2026-08-22 17:28:00'),
    versionedCacheKey('https://rakkan.dev/packages/rake?page=2&nonce=two', '2026-08-22 17:28:00'),
  );
  assert.notEqual(
    versionedCacheKey('https://rakkan.dev/packages/rake?page=2', '2026-08-22 17:28:00'),
    versionedCacheKey('https://rakkan.dev/packages/rake?page=3', '2026-08-22 17:28:00'),
  );
});

test('encoded paths that Astro resolves identically share one cache entry', async () => {
  const generation = '2026-08-22 17:28:00';
  const paths = ['/packages/rake', '/packages/r%61ke', '/packages/r%2561ke'];
  const keys = paths.map((path) => versionedCacheKey(`https://rakkan.dev${path}`, generation));

  assert.equal(new Set(keys).size, 1);
  for (const path of paths) assert.equal(isCacheableRequest('GET', `https://rakkan.dev${path}`), true);
});

test('a route-provided cache policy opts out of the shared cache', async () => {
  const cache = new MemoryCache();
  const response = await serveVersionedPage(
    cache,
    'https://rakkan.dev/',
    '2026-08-22 17:28:00',
    async () => new Response('private', { headers: { 'cache-control': 'private' } }),
  );

  assert.equal(response.headers.get('cache-control'), 'private');
  assert.equal(cache.entries.size, 0);
});

test('non-successful responses are not cached or rewritten', async () => {
  const cache = new MemoryCache();
  const response = await serveVersionedPage(
    cache,
    'https://rakkan.dev/',
    '2026-08-22 17:28:00',
    async () => new Response('unavailable', { status: 503 }),
  );

  assert.equal(response.status, 503);
  assert.equal(response.headers.get('cache-control'), null);
  assert.equal(cache.entries.size, 0);
});

test('a missing generation renders without consulting the shared cache', async () => {
  const cache = new MemoryCache();
  const response = await serveVersionedPage(cache, 'https://rakkan.dev/', null, async () => new Response('fresh'));

  assert.equal(await response.text(), 'fresh');
  assert.equal(response.headers.get('cache-control'), null);
  assert.equal(cache.entries.size, 0);
});

test('the generation tracker falls back only after observing a generation', async () => {
  const tracker = new GenerationTracker();
  const mayFallback = (error: unknown) => !(error instanceof SchemaVersionError);

  assert.equal(await tracker.current(async () => null), null);
  assert.equal(
    await tracker.current(async () => {
      throw new ExportUnavailableError('D1 unavailable');
    }, mayFallback),
    null,
  );
  assert.equal(await tracker.current(async () => '2026-08-22 17:28:00'), '2026-08-22 17:28:00');
  assert.equal(
    await tracker.current(async () => {
      throw new ExportUnavailableError('D1 unavailable');
    }, mayFallback),
    '2026-08-22 17:28:00',
  );
});

test('a warm generation serves its cached page while the acceptance marker is absent', async () => {
  const tracker = new GenerationTracker();
  const cache = new MemoryCache();
  let renders = 0;
  const render = async () => {
    renders += 1;
    return new Response('accepted generation');
  };
  const mayFallback = (error: unknown) => !(error instanceof SchemaVersionError);
  const accepted = await tracker.current(async () => '2026-08-22 17:28:00', mayFallback);
  await serveVersionedPage(cache, 'https://rakkan.dev/packages', accepted, render);

  const fallback = await tracker.current(async () => {
    throw new ExportUnavailableError('acceptance marker absent');
  }, mayFallback);
  const response = await serveVersionedPage(cache, 'https://rakkan.dev/packages', fallback, render);

  assert.equal(await response.text(), 'accepted generation');
  assert.equal(renders, 1);
});

test('the generation tracker does not hide errors classified as fatal', async () => {
  const tracker = new GenerationTracker();
  const fatal = new Error('schema mismatch');

  await tracker.current(async () => '2026-08-22 17:28:00');

  await assert.rejects(
    () =>
      tracker.current(
        async () => {
          throw fatal;
        },
        () => false,
      ),
    fatal,
  );
});

test('GET requests for rendered data pages use the shared cache regardless of ignored queries', () => {
  assert.equal(isCacheableRequest('GET', 'https://rakkan.dev/'), true);
  assert.equal(isCacheableRequest('GET', 'https://rakkan.dev/packages'), true);
  assert.equal(isCacheableRequest('GET', 'https://rakkan.dev/packages/rake'), true);
  assert.equal(isCacheableRequest('GET', 'https://rakkan.dev/cratesio'), true);
  assert.equal(isCacheableRequest('GET', 'https://rakkan.dev/cratesio/packages'), true);
  assert.equal(isCacheableRequest('GET', 'https://rakkan.dev/cratesio/packages/serde'), true);
  assert.equal(isCacheableRequest('GET', 'https://rakkan.dev/sitemap.xml'), true);

  assert.equal(isCacheableRequest('POST', 'https://rakkan.dev/'), false);
  assert.equal(isCacheableRequest('GET', 'https://rakkan.dev/?q=rake'), true);
  assert.equal(isCacheableRequest('GET', 'https://rakkan.dev/packages?nonce=1'), true);
  assert.equal(isCacheableRequest('GET', 'https://rakkan.dev/packages/rake?nonce=1'), true);
  assert.equal(isCacheableRequest('GET', 'https://rakkan.dev/about'), false);
  assert.equal(isCacheableRequest('GET', 'https://rakkan.dev/packages/rake/versions'), false);
  assert.equal(isCacheableRequest('GET', 'https://rakkan.dev/cratesio/search'), false);
  assert.equal(isCacheableRequest('GET', 'https://rakkan.dev/search?q=rake'), false);
  assert.equal(isCacheableRequest('GET', 'https://rakkan.dev/cratesio/packages/serde/versions'), false);
});
