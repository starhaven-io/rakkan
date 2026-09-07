import assert from 'node:assert/strict';
import { test } from 'node:test';

import { canonicalPageRedirect, clampPage, MAX_PAGE, pageHref, parsePage } from '../src/lib/pagination.ts';

test('page parsing is canonical and bounded', () => {
  assert.equal(parsePage(null), 1);
  assert.equal(parsePage(''), 1);
  assert.equal(parsePage('0'), 1);
  assert.equal(parsePage('-1'), 1);
  assert.equal(parsePage('2x'), 1);
  assert.equal(parsePage('0002'), 2);
  assert.equal(parsePage('999999999999999999999'), 1);
  assert.equal(parsePage((MAX_PAGE + 1).toString()), MAX_PAGE);
});

test('page calculations clamp to available content and emit canonical links', () => {
  assert.deepEqual(clampPage(9, 250, 100), { page: 3, pageCount: 3 });
  assert.deepEqual(clampPage(1, 0, 100), { page: 1, pageCount: 1 });
  assert.equal(pageHref('/packages', 1), '/packages');
  assert.equal(pageHref('/packages', 2), '/packages?page=2');
  assert.equal(canonicalPageRedirect('/packages', 11, 10), '/packages?page=10');
  assert.equal(canonicalPageRedirect('/packages', 10, 10), null);
});
