import type { APIRoute } from 'astro';

export const prerender = false;
import { allTracked, getDb, registryByName } from '../lib/d1.ts';

export const GET: APIRoute = async (context) => {
  const origin = (context.site?.href ?? 'https://rakkan.dev/').replace(/\/$/, '');
  const db = getDb();
  const registry = await registryByName(db, 'rubygems');
  const packages = registry ? await allTracked(db, registry.id) : [];

  const urls = [
    `${origin}/`,
    `${origin}/packages`,
    ...packages.map((pkg) => `${origin}/packages/${encodeURIComponent(pkg.name)}`),
  ];

  const body = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${urls.map((url) => `  <url><loc>${url}</loc></url>`).join('\n')}
</urlset>
`;
  return new Response(body, {
    headers: {
      'content-type': 'application/xml; charset=utf-8',
      'cache-control': 'public, max-age=86400',
    },
  });
};
