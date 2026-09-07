import { parsePage } from './pagination.ts';

export const EDGE_CACHE_CONTROL = 'public, max-age=1800';
export const NOT_FOUND_CACHE_CONTROL = 'public, max-age=60, s-maxage=300';
// The zone's Browser Cache TTL can raise a lower max-age, so client responses
// deliberately forbid storage while the separate edge copy remains cacheable.
export const BROWSER_CACHE_CONTROL = 'no-store';

const CACHEABLE_PATH = /^\/$|^\/packages(\/[^/]+)?$|^\/cratesio(\/packages(\/[^/]+)?)?$|^\/sitemap\.xml$/;
const PAGINATED_PATH = /^\/packages(\/[^/]+)?$|^\/cratesio\/packages(\/[^/]+)?$/;

function normalizedUrl(requestUrl: string | URL): URL {
  const url = new URL(requestUrl);
  let pathname = url.pathname;
  for (let iteration = 0; iteration < 10; iteration += 1) {
    let decoded: string;
    try {
      decoded = decodeURI(pathname);
    } catch {
      break;
    }
    if (decoded === pathname) break;
    pathname = decoded;
  }
  url.pathname = pathname.replace(/\/{2,}/g, '/');
  return url;
}

export interface EdgeCache {
  match(key: string): Promise<Response | undefined>;
  put(key: string, response: Response): Promise<void>;
}

interface MutableResponse {
  status?: number;
  headers: Headers;
}

// Astro only propagates response mutations made during route frontmatter;
// calling this from a nested component is too late in response construction.
export function markRouteNotFound(response: MutableResponse): void {
  response.status = 404;
  response.headers.set('cache-control', NOT_FOUND_CACHE_CONTROL);
}

export class GenerationTracker {
  #lastGeneration: string | null = null;

  async current(
    load: () => Promise<string | null>,
    mayFallback: (error: unknown) => boolean = () => true,
  ): Promise<string | null> {
    try {
      const generatedAt = await load();
      if (generatedAt !== null) this.#lastGeneration = generatedAt;
      return generatedAt ?? this.#lastGeneration;
    } catch (error) {
      if (!mayFallback(error)) throw error;
      return this.#lastGeneration;
    }
  }
}

export function isCacheableRequest(method: string, requestUrl: string | URL): boolean {
  const url = normalizedUrl(requestUrl);
  return method === 'GET' && CACHEABLE_PATH.test(url.pathname);
}

export function versionedCacheKey(requestUrl: string | URL, generatedAt: string): string {
  const url = normalizedUrl(requestUrl);
  const page = PAGINATED_PATH.test(url.pathname) ? parsePage(url.searchParams.get('page')) : 1;
  url.search = '';
  if (page > 1) url.searchParams.set('page', page.toString());
  url.searchParams.set('__rakkan_generation', generatedAt);
  return url.toString();
}

function browserResponse(response: Response): Response {
  const result = new Response(response.body, response);
  result.headers.set('cache-control', BROWSER_CACHE_CONTROL);
  return result;
}

export async function serveVersionedPage(
  cache: EdgeCache,
  requestUrl: string | URL,
  generatedAt: string | null,
  render: () => Promise<Response>,
): Promise<Response> {
  if (!generatedAt) return render();

  const key = versionedCacheKey(requestUrl, generatedAt);
  const hit = await cache.match(key);
  if (hit) return browserResponse(hit);

  const response = await render();
  if (response.status !== 200 || response.headers.has('cache-control')) return response;

  const stored = response.clone();
  stored.headers.set('cache-control', EDGE_CACHE_CONTROL);
  await cache.put(key, stored);

  response.headers.set('cache-control', BROWSER_CACHE_CONTROL);
  return response;
}
