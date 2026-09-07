import { escapeLike } from './format.ts';
import { clampPage, PACKAGE_PAGE_SIZE, VERSION_PAGE_SIZE } from './pagination.ts';
import schemaContract from '../../schema-contract.json' with { type: 'json' };

function validVersion(value: unknown): value is number {
  return Number.isInteger(value) && Number(value) > 0;
}

if (
  !validVersion(schemaContract.version) ||
  !Array.isArray(schemaContract.compatibleVersions) ||
  schemaContract.compatibleVersions.length === 0 ||
  !schemaContract.compatibleVersions.every(validVersion) ||
  new Set(schemaContract.compatibleVersions).size !== schemaContract.compatibleVersions.length ||
  !schemaContract.compatibleVersions.includes(schemaContract.version)
) {
  throw new Error('schema-contract.json must define a positive version and compatible version set');
}

export const EXPECTED_SCHEMA_VERSION = schemaContract.version;
export const COMPATIBLE_SCHEMA_VERSIONS: readonly number[] = Object.freeze([...schemaContract.compatibleVersions]);
export const LEGACY_SCHEMA_VERSION = 1;

export class SchemaVersionError extends Error {
  override name = 'SchemaVersionError';
}

export class ExportUnavailableError extends Error {
  override name = 'ExportUnavailableError';
}

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

export interface ExportMetadata {
  generated_at: string;
  schema_version: number;
}

export interface HealthPayload {
  status: 'ok';
  schemaVersion: number;
  compatibleVersions: number[];
  generatedAt: string;
}

export interface CompatibilityPayload {
  status: 'ok';
  compatibleVersions: number[];
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

export interface PackageDetail {
  registry: Registry | null;
  pkg: PackageRow | null;
  versions: VersionRow[];
  totalVersions: number;
  page: number;
  pageCount: number;
}

export interface PageResult<T> {
  items: T[];
  total: number;
  page: number;
  pageCount: number;
}

export interface TrackedSummary {
  total: number;
  provenant: number;
}

export async function exportMetadata(
  db: D1,
  compatibleVersions: readonly number[] = COMPATIBLE_SCHEMA_VERSIONS,
): Promise<ExportMetadata> {
  let row: Record<string, unknown> | null;
  try {
    row = await db.prepare('SELECT * FROM export_meta LIMIT 1').first<Record<string, unknown>>();
  } catch (error) {
    if (error instanceof Error && /no such table:\s*export_meta/i.test(error.message)) {
      throw new ExportUnavailableError('D1 export metadata table is temporarily unavailable');
    }
    throw error;
  }
  if (!row) throw new ExportUnavailableError('D1 export metadata is temporarily unavailable');

  const keys = Object.keys(row).sort();
  const legacy = keys.length === 1 && keys[0] === 'generated_at';
  const versioned = keys.length === 2 && keys[0] === 'generated_at' && keys[1] === 'schema_version';
  const schemaVersion = legacy ? LEGACY_SCHEMA_VERSION : row.schema_version;
  if (!legacy && !versioned) {
    throw new SchemaVersionError('D1 export metadata has an unknown schema');
  }
  if (!validVersion(schemaVersion) || !compatibleVersions.includes(schemaVersion)) {
    throw new SchemaVersionError(`D1 schema version ${String(schemaVersion)} is not compatible with this site`);
  }
  if (
    typeof row.generated_at !== 'string' ||
    !/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d{1,6})?$/.test(row.generated_at)
  ) {
    throw new SchemaVersionError('D1 export generation timestamp is invalid');
  }
  return { generated_at: row.generated_at, schema_version: schemaVersion };
}

export async function exportGeneratedAt(db: D1): Promise<string> {
  return (await exportMetadata(db)).generated_at;
}

export function compatibilityPayload(): CompatibilityPayload {
  return {
    status: 'ok',
    compatibleVersions: [...COMPATIBLE_SCHEMA_VERSIONS],
  };
}

export function healthPayload(metadata: ExportMetadata): HealthPayload {
  return {
    ...compatibilityPayload(),
    schemaVersion: metadata.schema_version,
    generatedAt: metadata.generated_at,
  };
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

export async function trackedSummary(db: D1, registryId: number): Promise<TrackedSummary> {
  const row = await db
    .prepare(
      `SELECT COUNT(*) AS total,
              COALESCE(SUM(CASE WHEN first_provenant_at IS NOT NULL THEN 1 ELSE 0 END), 0) AS provenant
         FROM packages WHERE registry_id = ? AND tracked = 1`,
    )
    .bind(registryId)
    .first<TrackedSummary>();
  return row ?? { total: 0, provenant: 0 };
}

export async function trackedPage(
  db: D1,
  registryId: number,
  requestedPage: number,
  pageSize = PACKAGE_PAGE_SIZE,
): Promise<PageResult<PackageRow>> {
  const summary = await trackedSummary(db, registryId);
  const { page, pageCount } = clampPage(requestedPage, summary.total, pageSize);
  const { results } = await db
    .prepare(
      `SELECT name, rank, downloads_total, first_provenant_at
         FROM packages
        WHERE registry_id = ? AND tracked = 1
        ORDER BY rank ASC LIMIT ? OFFSET ?`,
    )
    .bind(registryId, pageSize, (page - 1) * pageSize)
    .all<PackageRow>();
  return { items: results, total: summary.total, page, pageCount };
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
        ORDER BY v.published_at DESC, v.id DESC`,
    )
    .bind(registryId, name)
    .all<VersionRow>();
  return results;
}

export async function versionsPage(
  db: D1,
  registryId: number,
  name: string,
  requestedPage: number,
  pageSize = VERSION_PAGE_SIZE,
): Promise<PageResult<VersionRow>> {
  const count = await db
    .prepare(
      `SELECT COUNT(*) AS total
         FROM package_versions v JOIN packages p ON p.id = v.package_id
        WHERE p.registry_id = ? AND p.name = ?`,
    )
    .bind(registryId, name)
    .first<{ total: number }>();
  const total = count?.total ?? 0;
  const { page, pageCount } = clampPage(requestedPage, total, pageSize);
  const { results } = await db
    .prepare(
      `SELECT v.number, v.platform, v.published_at, v.prerelease, v.yanked,
              v.provenance_kind, v.source_repository, v.run_url,
              v.attestation_count, v.provenance_checked_at
         FROM package_versions v JOIN packages p ON p.id = v.package_id
        WHERE p.registry_id = ? AND p.name = ?
        ORDER BY v.published_at DESC, v.id DESC LIMIT ? OFFSET ?`,
    )
    .bind(registryId, name, pageSize, (page - 1) * pageSize)
    .all<VersionRow>();
  return { items: results, total, page, pageCount };
}

export async function loadPackageDetail(
  db: D1,
  registryName: string,
  packageName: string,
  requestedPage = 1,
): Promise<PackageDetail> {
  const registry = await registryByName(db, registryName);
  const pkg = registry ? await packageByName(db, registry.id, packageName) : null;
  const result = registry && pkg ? await versionsPage(db, registry.id, pkg.name, requestedPage) : null;
  return {
    registry,
    pkg,
    versions: result?.items ?? [],
    totalVersions: result?.total ?? 0,
    page: result?.page ?? 1,
    pageCount: result?.pageCount ?? 1,
  };
}

export async function searchPackages(db: D1, registryId: number, query: string, limit = 50): Promise<PackageRow[]> {
  const escaped = escapeLike(query);
  const { results } = await db
    .prepare(
      `SELECT name, rank, downloads_total, first_provenant_at
         FROM packages
        WHERE registry_id = ? AND tracked = 1 AND name LIKE ? ESCAPE '\\'
        ORDER BY downloads_total DESC, name ASC LIMIT ?`,
    )
    .bind(registryId, `%${escaped}%`, limit)
    .all<PackageRow>();
  return results;
}
