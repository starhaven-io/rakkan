import assert from 'node:assert/strict';
import { test } from 'node:test';
import { adoptionTrend } from '../src/lib/history.ts';

function snapshot(date: string, adopted: number) {
  return {
    taken_on: date,
    tracked_packages: 1000,
    provenant_packages: adopted,
    tracked_versions: 0,
    provenant_versions: 0,
  };
}

test('the trend respects elapsed days and compares the latest two completed observations', () => {
  const trend = adoptionTrend([snapshot('2026-11-10', 109), snapshot('2026-11-09', 107), snapshot('2026-11-01', 100)]);
  assert.ok(trend);
  assert.equal(trend.previous.date, '2026-11-09');
  assert.equal(trend.delta, 0.2);
  assert.equal(trend.lower, 10);
  assert.equal(trend.upper, 11);
  assert.equal(trend.points, '0.00,100.00 88.89,30.00 100.00,10.00');
});

test('flat zero and full coverage have a visible scale and one observation has no slope', () => {
  assert.equal(adoptionTrend([]), null);
  assert.equal(adoptionTrend([snapshot('2026-11-01', 0)]), null);
  for (const [count, lower, upper] of [
    [0, 0, 1],
    [1000, 99, 100],
  ]) {
    const trend = adoptionTrend([snapshot('2026-11-10', count), snapshot('2026-11-01', count)]);
    assert.ok(trend);
    assert.deepEqual([trend.lower, trend.upper, trend.delta], [lower, upper, 0]);
  }
});
