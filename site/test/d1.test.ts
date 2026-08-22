import assert from 'node:assert/strict';
import { test } from 'node:test';

import { snapshotSeries, type D1, type D1PreparedStatement, type Snapshot } from '../src/lib/d1.ts';

test('snapshotSeries returns the newest observation first', async () => {
  const rows: Snapshot[] = [
    {
      taken_on: '2026-08-10',
      tracked_packages: 1000,
      provenant_packages: 96,
      tracked_versions: 10_000,
      provenant_versions: 666,
    },
    {
      taken_on: '2026-08-17',
      tracked_packages: 1000,
      provenant_packages: 97,
      tracked_versions: 10_000,
      provenant_versions: 667,
    },
  ];
  let sql = '';
  let bindings: unknown[] = [];
  const statement: D1PreparedStatement = {
    bind(...values: unknown[]) {
      bindings = values;
      return this;
    },
    async all<T>() {
      const ordered = rows.toSorted((left, right) =>
        sql.includes('ORDER BY taken_on DESC')
          ? right.taken_on.localeCompare(left.taken_on)
          : left.taken_on.localeCompare(right.taken_on),
      );
      return { results: ordered as T[] };
    },
    async first<T>() {
      return null as T | null;
    },
  };
  const db: D1 = {
    prepare(query: string) {
      sql = query;
      return statement;
    },
  };

  const snapshots = await snapshotSeries(db, 7);

  assert.deepEqual(bindings, [7]);
  assert.deepEqual(
    snapshots.map((snapshot) => snapshot.taken_on),
    ['2026-08-17', '2026-08-10'],
  );
});
