import { env } from 'cloudflare:workers';
import type { D1 } from './d1.ts';

export function getDb(): D1 {
  return (env as unknown as { DB: D1 }).DB;
}
