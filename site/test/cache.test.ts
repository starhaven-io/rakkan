import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  BROWSER_CACHE_CONTROL,
  EDGE_CACHE_CONTROL,
  GenerationTracker,
  isCacheableRequest,
  serveVersionedPage,
  versionedCacheKey,
  type EdgeCache,
} from '../src/lib/cache.ts';

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
    cache.entries
      .get(versionedCacheKey(url, '2026-08-22 17:28:00'))
      ?.headers.get('cache-control'),
    EDGE_CACHE_CONTROL,
  );
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
  const response = await serveVersionedPage(
    cache,
    'https://rakkan.dev/',
    null,
    async () => new Response('fresh'),
  );

  assert.equal(await response.text(), 'fresh');
  assert.equal(response.headers.get('cache-control'), null);
  assert.equal(cache.entries.size, 0);
});

test('the generation tracker falls back only after observing a generation', async () => {
  const tracker = new GenerationTracker();

  assert.equal(await tracker.current(async () => null), null);
  assert.equal(
    await tracker.current(async () => {
      throw new Error('D1 unavailable');
    }),
    null,
  );
  assert.equal(await tracker.current(async () => '2026-08-22 17:28:00'), '2026-08-22 17:28:00');
  assert.equal(
    await tracker.current(async () => {
      throw new Error('D1 unavailable');
    }),
    '2026-08-22 17:28:00',
  );
});

test('only bare GET requests for rendered data pages use the shared cache', () => {
  assert.equal(isCacheableRequest('GET', 'https://rakkan.dev/'), true);
  assert.equal(isCacheableRequest('GET', 'https://rakkan.dev/packages'), true);
  assert.equal(isCacheableRequest('GET', 'https://rakkan.dev/packages/rake'), true);
  assert.equal(isCacheableRequest('GET', 'https://rakkan.dev/sitemap.xml'), true);

  assert.equal(isCacheableRequest('POST', 'https://rakkan.dev/'), false);
  assert.equal(isCacheableRequest('GET', 'https://rakkan.dev/?q=rake'), false);
  assert.equal(isCacheableRequest('GET', 'https://rakkan.dev/about'), false);
  assert.equal(isCacheableRequest('GET', 'https://rakkan.dev/packages/rake/versions'), false);
});
