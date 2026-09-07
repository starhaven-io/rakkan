import type { APIRoute } from 'astro';
import { compatibilityPayload } from '../../../lib/d1.ts';

export const prerender = false;

export const GET: APIRoute = async () => {
  return Response.json(compatibilityPayload(), { headers: { 'cache-control': 'no-store' } });
};
