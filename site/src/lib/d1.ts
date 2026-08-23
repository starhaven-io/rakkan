import { escapeLike } from './format.ts';

// Minimal D1 surface (avoids a @cloudflare/workers-types dependency). The
// database is produced by `rake export:d1` on the
// Ruby side; booleans are 1/0 integers and timestamps are UTC text.
export interface D1PreparedStatement {
  bind(...values: unknown[]): D1PreparedStatement;
  all<T = unknown>(): Promise<{ results: T[] }>;
  first<T = unknown>(): Promise<T | null>;
}
export interface D1 {
  prepare(sql: string): D1PreparedStatement;
}

export interface Registry {
  id: number;
  name: string;
  display_name: string;
  url: string;
  feed_synced_at: string | null;
}

export interface Snapshot {
  taken_on: string;
  tracked_packages: number;
  provenant_packages: number;
  tracked_versions: number;
  provenant_versions: number;
}

export interface PackageRow {
  name: string;
  rank: number | null;
  downloads_total: number | null;
  first_provenant_at: string | null;
  tracked?: number;
}

export interface VersionRow {
  number: string;
  platform: string;
  published_at: string | null;
  prerelease: number;
  yanked: number;
  provenance_kind: string | null;
  source_repository: string | null;
  run_url: string | null;
  attestation_count: number;
  provenance_checked_at: string | null;
}

export async function exportGeneratedAt(db: D1): Promise<string | null> {
  const row = await db.prepare('SELECT generated_at FROM export_meta LIMIT 1').first<{ generated_at: string }>();
  return row?.generated_at ?? null;
}

export async function registryByName(db: D1, name: string): Promise<Registry | null> {
  return db
    .prepare('SELECT id, name, display_name, url, feed_synced_at FROM registries WHERE name = ?')
    .bind(name)
    .first<Registry>();
}

export async function latestSnapshot(db: D1, registryId: number): Promise<Snapshot | null> {
  return db
    .prepare(
      `SELECT taken_on, tracked_packages, provenant_packages, tracked_versions, provenant_versions
         FROM adoption_snapshots WHERE registry_id = ? ORDER BY taken_on DESC LIMIT 1`,
    )
    .bind(registryId)
    .first<Snapshot>();
}

export async function snapshotSeries(db: D1, registryId: number): Promise<Snapshot[]> {
  const { results } = await db
    .prepare(
      `SELECT taken_on, tracked_packages, provenant_packages, tracked_versions, provenant_versions
         FROM adoption_snapshots WHERE registry_id = ? ORDER BY taken_on DESC`,
    )
    .bind(registryId)
    .all<Snapshot>();
  return results;
}

export async function recentConversions(db: D1, registryId: number, limit = 10): Promise<PackageRow[]> {
  const { results } = await db
    .prepare(
      `SELECT name, rank, downloads_total, first_provenant_at
         FROM packages
        WHERE registry_id = ? AND tracked = 1 AND first_provenant_at IS NOT NULL
        ORDER BY first_provenant_at DESC LIMIT ?`,
    )
    .bind(registryId, limit)
    .all<PackageRow>();
  return results;
}

export async function topPackages(db: D1, registryId: number, limit = 10): Promise<PackageRow[]> {
  const { results } = await db
    .prepare(
      `SELECT name, rank, downloads_total, first_provenant_at
         FROM packages
        WHERE registry_id = ? AND tracked = 1
        ORDER BY rank ASC LIMIT ?`,
    )
    .bind(registryId, limit)
    .all<PackageRow>();
  return results;
}

export async function allTracked(db: D1, registryId: number): Promise<PackageRow[]> {
  const { results } = await db
    .prepare(
      `SELECT name, rank, downloads_total, first_provenant_at
         FROM packages
        WHERE registry_id = ? AND tracked = 1
        ORDER BY rank ASC`,
    )
    .bind(registryId)
    .all<PackageRow>();
  return results;
}

// Deliberately does not filter on tracked: packages that leave the top
// 1,000 keep working permalinks and render as no-longer-tracked.
export async function packageByName(db: D1, registryId: number, name: string): Promise<PackageRow | null> {
  return db
    .prepare(
      `SELECT name, rank, downloads_total, first_provenant_at, tracked
         FROM packages WHERE registry_id = ? AND name = ?`,
    )
    .bind(registryId, name)
    .first<PackageRow>();
}

export async function versionsOf(db: D1, registryId: number, name: string): Promise<VersionRow[]> {
  const { results } = await db
    .prepare(
      `SELECT v.number, v.platform, v.published_at, v.prerelease, v.yanked,
              v.provenance_kind, v.source_repository, v.run_url,
              v.attestation_count, v.provenance_checked_at
         FROM package_versions v JOIN packages p ON p.id = v.package_id
        WHERE p.registry_id = ? AND p.name = ?
        ORDER BY v.published_at DESC`,
    )
    .bind(registryId, name)
    .all<VersionRow>();
  return results;
}

export async function searchPackages(db: D1, registryId: number, query: string, limit = 50): Promise<PackageRow[]> {
  const escaped = escapeLike(query);
  const { results } = await db
    .prepare(
      `SELECT name, rank, downloads_total, first_provenant_at
         FROM packages
        WHERE registry_id = ? AND tracked = 1 AND name LIKE ? ESCAPE '\\'
        ORDER BY downloads_total DESC LIMIT ?`,
    )
    .bind(registryId, `%${escaped}%`, limit)
    .all<PackageRow>();
  return results;
}
