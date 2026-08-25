import type { APIRoute } from 'astro';

export const prerender = false;
import { getDb } from '../lib/db.ts';
import { allTracked, registryByName } from '../lib/d1.ts';
import { REGISTRY_SLUGS, registrySite } from '../lib/registries.ts';

export const GET: APIRoute = async (context) => {
  const origin = (context.site?.href ?? 'https://rakkan.dev/').replace(/\/$/, '');
  const db = getDb();
  const registryPackages = await Promise.all(
    REGISTRY_SLUGS.map(async (slug) => {
      const registry = await registryByName(db, slug);
      return [slug, registry ? await allTracked(db, registry.id) : []] as const;
    }),
  );

  const urls = registryPackages.flatMap(([slug, packages]) => {
    const site = registrySite(slug);
    return [
      `${origin}${site.overviewPath}`,
      `${origin}${site.packagesPath}`,
      ...packages.map((pkg) => `${origin}${site.packagePath(pkg.name)}`),
    ];
  });

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
