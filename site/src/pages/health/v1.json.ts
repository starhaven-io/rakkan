import type { APIRoute } from 'astro';
import { getDb } from '../../lib/db.ts';
import { exportMetadata, healthPayload } from '../../lib/d1.ts';

export const prerender = false;

export const GET: APIRoute = async () => {
  const metadata = await exportMetadata(getDb());
  return Response.json(healthPayload(metadata), { headers: { 'cache-control': 'no-store' } });
};
