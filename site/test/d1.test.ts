import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test, type TestContext } from 'node:test';
import { DatabaseSync, type SQLInputValue, type StatementSync } from 'node:sqlite';

import {
  allTracked,
  compatibilityPayload,
  COMPATIBLE_SCHEMA_VERSIONS,
  EXPECTED_SCHEMA_VERSION,
  ExportUnavailableError,
  exportGeneratedAt,
  exportMetadata,
  healthPayload,
  SchemaVersionError,
  latestSnapshot,
  loadPackageDetail,
  packageByName,
  recentConversions,
  registryByName,
  searchPackages,
  snapshotSeries,
  trackedPage,
  trackedSummary,
  topPackages,
  versionsPage,
  versionsOf,
  type D1,
  type D1PreparedStatement,
} from '../src/lib/d1.ts';

class SqliteStatement implements D1PreparedStatement {
  private values: SQLInputValue[] = [];
  private readonly statement: StatementSync;

  constructor(statement: StatementSync) {
    this.statement = statement;
  }

  bind(...values: unknown[]): D1PreparedStatement {
    this.values = values as SQLInputValue[];
    return this;
  }

  async all<T>(): Promise<{ results: T[] }> {
    return { results: this.statement.all(...this.values) as T[] };
  }

  async first<T>(): Promise<T | null> {
    return (this.statement.get(...this.values) as T | undefined) ?? null;
  }
}

class SqliteD1 implements D1 {
  readonly sqlite = new DatabaseSync(':memory:');

  constructor() {
    this.sqlite.exec(readFileSync(new URL('../../config/db/structure.sql', import.meta.url), 'utf8'));
    this.sqlite.exec(`
      CREATE TABLE export_meta (generated_at TEXT NOT NULL, schema_version INTEGER NOT NULL);
      INSERT INTO export_meta VALUES ('2026-08-22 17:28:00', ${EXPECTED_SCHEMA_VERSION});
      INSERT INTO registries
        (id, name, display_name, url, feed_synced_at, created_at, updated_at)
      VALUES
        (1, 'rubygems', 'RubyGems.org', 'https://rubygems.org', '2026-08-22 17:00:00',
          '2026-08-22 17:00:00', '2026-08-22 17:00:00'),
        (2, 'cratesio', 'crates.io', 'https://crates.io', '2026-08-22 02:00:00',
          '2026-08-22 02:00:00', '2026-08-22 02:00:00');
      INSERT INTO packages
        (id, registry_id, name, rank, downloads_total, first_provenant_at, tracked, created_at, updated_at)
      VALUES
        (1, 1, 'rack-main', 1, 9000, '2026-08-20 12:00:00', 1, '2026-08-20 12:00:00', '2026-08-20 12:00:00'),
        (2, 1, 'rack%literal', 2, 7000, '2026-08-21 12:00:00', 1, '2026-08-21 12:00:00', '2026-08-21 12:00:00'),
        (3, 1, 'rack-retired', NULL, 6000, NULL, 0, '2026-08-19 12:00:00', '2026-08-19 12:00:00'),
        (4, 2, 'rack-main', 1, 8000, '2026-08-22 12:00:00', 1, '2026-08-22 12:00:00', '2026-08-22 12:00:00');
      INSERT INTO adoption_snapshots
        (id, registry_id, taken_on, tracked_packages, provenant_packages,
          tracked_versions, provenant_versions, created_at)
      VALUES
        (1, 1, '2026-08-10', 1000, 96, 10000, 666, '2026-08-10 12:00:00'),
        (2, 1, '2026-08-17', 1000, 97, 10001, 667, '2026-08-17 12:00:00'),
        (3, 2, '2026-08-18', 1000, 12, 41285, 12, '2026-08-18 12:00:00');
      INSERT INTO package_versions
        (id, package_id, number, platform, published_at, prerelease, latest, yanked,
          provenance_kind, source_repository, run_url, attestation_count,
          provenance_checked_at, created_at, updated_at)
      VALUES
        (1, 1, '1.0.0', 'ruby', '2026-08-10 12:00:00', 0, 0, 0, NULL, NULL, NULL, 0,
          '2026-08-20 00:00:00', '2026-08-10 12:00:00', '2026-08-20 00:00:00'),
        (2, 1, '2.0.0', 'ruby', '2026-08-20 12:00:00', 0, 1, 0, 'sigstore_attestation',
          'https://github.com/rack/rack', 'https://github.com/rack/rack/actions/runs/1', 1,
          '2026-08-21 00:00:00', '2026-08-20 12:00:00', '2026-08-21 00:00:00'),
        (3, 4, '3.0.0', '', '2026-08-22 12:00:00', 0, 1, 0, 'trustpub_metadata',
          'https://github.com/rust-lang/rack', NULL, 1,
          '2026-08-22 13:00:00', '2026-08-22 12:00:00', '2026-08-22 13:00:00');
    `);
  }

  prepare(sql: string): D1PreparedStatement {
    return new SqliteStatement(this.sqlite.prepare(sql));
  }
}

function database(t: TestContext): SqliteD1 {
  const db = new SqliteD1();
  t.after(() => db.sqlite.close());
  return db;
}

test('metadata and registry lookups preserve missing-row semantics', async (t) => {
  const db = database(t);

  assert.equal(await exportGeneratedAt(db), '2026-08-22 17:28:00');
  assert.deepEqual(
    { ...(await registryByName(db, 'cratesio')) },
    {
      id: 2,
      name: 'cratesio',
      display_name: 'crates.io',
      url: 'https://crates.io',
      feed_synced_at: '2026-08-22 02:00:00',
    },
  );
  assert.equal(await registryByName(db, 'missing'), null);
  db.sqlite.exec('DELETE FROM export_meta');
  await assert.rejects(() => exportGeneratedAt(db), ExportUnavailableError);
});

test('metadata lookup fails closed on an incompatible D1 schema contract', async (t) => {
  const db = database(t);
  db.sqlite.exec(`UPDATE export_meta SET schema_version = ${EXPECTED_SCHEMA_VERSION + 1}`);

  await assert.rejects(() => exportGeneratedAt(db), SchemaVersionError);
});

test('metadata lookup rejects unrecognized columns even when the version is compatible', async (t) => {
  const db = database(t);
  db.sqlite.exec('ALTER TABLE export_meta ADD COLUMN unexpected TEXT');

  await assert.rejects(() => exportMetadata(db), SchemaVersionError);
});

test('metadata compatibility sets support an N to N+1 rollout bridge', async (t) => {
  const db = database(t);
  db.sqlite.exec(`UPDATE export_meta SET schema_version = ${EXPECTED_SCHEMA_VERSION + 1}`);

  const metadata = await exportMetadata(db, [EXPECTED_SCHEMA_VERSION, EXPECTED_SCHEMA_VERSION + 1]);

  assert.equal(metadata.schema_version, EXPECTED_SCHEMA_VERSION + 1);
  assert.ok(COMPATIBLE_SCHEMA_VERSIONS.includes(EXPECTED_SCHEMA_VERSION));
});

test('metadata rejects an unversioned export marker', async (t) => {
  const db = database(t);
  db.sqlite.exec('DROP TABLE export_meta; CREATE TABLE export_meta (generated_at TEXT NOT NULL);');
  db.sqlite.exec("INSERT INTO export_meta VALUES ('2026-08-22 17:28:00')");

  await assert.rejects(() => exportMetadata(db), SchemaVersionError);
});

test('health metadata advertises the deployed Worker compatibility set', async (t) => {
  const db = database(t);

  assert.deepEqual(healthPayload(await exportMetadata(db)), {
    status: 'ok',
    schemaVersion: EXPECTED_SCHEMA_VERSION,
    compatibleVersions: [...COMPATIBLE_SCHEMA_VERSIONS],
    generatedAt: '2026-08-22 17:28:00',
  });
  assert.deepEqual(compatibilityPayload(), {
    status: 'ok',
    compatibleVersions: [...COMPATIBLE_SCHEMA_VERSIONS],
  });
});

test('metadata lookup fails closed on missing columns, invalid generations, and a missing table', async (t) => {
  const db = database(t);
  db.sqlite.exec(
    'DROP TABLE export_meta; CREATE TABLE export_meta (generated_at TEXT NOT NULL, schema_version INTEGER);',
  );
  db.sqlite.exec("INSERT INTO export_meta VALUES ('2026-08-22 17:28:00', NULL)");
  await assert.rejects(() => exportGeneratedAt(db), SchemaVersionError);

  db.sqlite.exec(
    'DROP TABLE export_meta; CREATE TABLE export_meta (generated_at TEXT NOT NULL, schema_version INTEGER NOT NULL);',
  );
  db.sqlite.exec(`INSERT INTO export_meta VALUES ('not-a-timestamp', ${EXPECTED_SCHEMA_VERSION})`);
  await assert.rejects(() => exportGeneratedAt(db), SchemaVersionError);

  db.sqlite.exec('DROP TABLE export_meta');
  await assert.rejects(() => exportGeneratedAt(db), ExportUnavailableError);

  db.sqlite.exec('CREATE TABLE export_meta (generated_at TEXT NOT NULL, schema_version INTEGER NOT NULL)');
  await assert.rejects(() => exportGeneratedAt(db), ExportUnavailableError);
});

test('snapshot queries stay registry-scoped and newest-first', async (t) => {
  const db = database(t);

  const latest = await latestSnapshot(db, 1);
  const snapshots = await snapshotSeries(db, 1);

  assert.equal(latest?.taken_on, '2026-08-17');
  assert.deepEqual(
    snapshots.map((snapshot) => snapshot.taken_on),
    ['2026-08-17', '2026-08-10'],
  );
});

test('package lists enforce tracking, ordering, and registry boundaries', async (t) => {
  const db = database(t);

  assert.deepEqual(
    (await recentConversions(db, 1, 1)).map((pkg) => pkg.name),
    ['rack%literal'],
  );
  assert.deepEqual(
    (await topPackages(db, 1)).map((pkg) => pkg.name),
    ['rack-main', 'rack%literal'],
  );
  assert.deepEqual(
    (await allTracked(db, 2)).map((pkg) => pkg.name),
    ['rack-main'],
  );
  assert.equal((await packageByName(db, 1, 'rack-retired'))?.tracked, 0);
  assert.equal(await packageByName(db, 2, 'rack-retired'), null);
  assert.deepEqual({ ...(await trackedSummary(db, 1)) }, { total: 2, provenant: 2 });
  const secondPage = await trackedPage(db, 1, 2, 1);
  assert.equal(secondPage.total, 2);
  assert.equal(secondPage.pageCount, 2);
  assert.deepEqual(
    secondPage.items.map((pkg) => pkg.name),
    ['rack%literal'],
  );
});

test('version and search queries execute against the exported SQLite shape', async (t) => {
  const db = database(t);

  assert.deepEqual(
    (await versionsOf(db, 1, 'rack-main')).map((version) => version.number),
    ['2.0.0', '1.0.0'],
  );
  assert.deepEqual(
    (await versionsOf(db, 2, 'rack-main')).map((version) => version.number),
    ['3.0.0'],
  );
  const secondPage = await versionsPage(db, 1, 'rack-main', 2, 1);
  assert.equal(secondPage.total, 2);
  assert.equal(secondPage.pageCount, 2);
  assert.deepEqual(
    secondPage.items.map((version) => version.number),
    ['1.0.0'],
  );
  assert.deepEqual(
    (await searchPackages(db, 1, 'rack%', 10)).map((pkg) => pkg.name),
    ['rack%literal'],
  );
  assert.deepEqual(
    (await searchPackages(db, 1, 'rack', 1)).map((pkg) => pkg.name),
    ['rack-main'],
  );
  assert.deepEqual(
    (await searchPackages(db, 2, 'rack', 10)).map((pkg) => pkg.name),
    ['rack-main'],
  );
});

test('package detail loading keeps package and versions inside one registry', async (t) => {
  const db = database(t);

  const rubygems = await loadPackageDetail(db, 'rubygems', 'rack-main');
  const cratesio = await loadPackageDetail(db, 'cratesio', 'rack-main');
  const missingPackage = await loadPackageDetail(db, 'cratesio', 'missing');
  const missingRegistry = await loadPackageDetail(db, 'missing', 'rack-main');

  assert.equal(rubygems.registry?.name, 'rubygems');
  assert.equal(rubygems.pkg?.name, 'rack-main');
  assert.deepEqual(
    rubygems.versions.map((version) => version.number),
    ['2.0.0', '1.0.0'],
  );
  assert.equal(cratesio.registry?.name, 'cratesio');
  assert.equal(cratesio.pkg?.name, 'rack-main');
  assert.deepEqual(
    cratesio.versions.map((version) => version.number),
    ['3.0.0'],
  );
  assert.equal(missingPackage.pkg, null);
  assert.deepEqual(missingPackage.versions, []);
  assert.deepEqual(missingRegistry, {
    registry: null,
    pkg: null,
    versions: [],
    totalVersions: 0,
    page: 1,
    pageCount: 1,
  });
});
