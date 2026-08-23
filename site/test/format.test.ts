import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  escapeLike,
  formatCount,
  packageNoun,
  percentage,
  provenanceLabel,
  repositoryLabel,
  safeHttpsUrl,
  searchResultSummary,
  shortDate,
  utcStamp,
} from '../src/lib/format.ts';

test('percentage matches the engine semantics, including decimal halfway values', () => {
  assert.equal(percentage(96, 1000), 9.6);
  assert.equal(percentage(1, 0), 0.0);
  assert.equal(percentage(255, 10000), 2.6); // Ruby Float#round(1) on 2.55
  assert.equal(percentage(664, 104654), 0.6);
});

test('formatCount groups thousands', () => {
  assert.equal(formatCount(104654), '104,654');
  assert.equal(formatCount(null), '0');
});

test('escapeLike neutralizes LIKE metacharacters', () => {
  assert.equal(escapeLike('rack%'), 'rack\\%');
  assert.equal(escapeLike('a_b'), 'a\\_b');
  assert.equal(escapeLike('back\\slash'), 'back\\\\slash');
  assert.equal(escapeLike('plain'), 'plain');
});

test('safeHttpsUrl admits only absolute https with a host and no userinfo', () => {
  const ok = 'https://github.com/sigstore/sigstore-ruby';
  assert.equal(safeHttpsUrl(ok), ok);
  for (const bad of [
    'javascript:alert(1)',
    'data:text/html;base64,PGI+',
    '//evil.example/x',
    'http://github.com/x/y',
    'https://user:secret@github.com/x',
    'not a url at all',
    null,
    '',
  ]) {
    assert.equal(safeHttpsUrl(bad), null, `expected ${JSON.stringify(bad)} to be rejected`);
  }
});

test('shortDate renders exporter timestamps and bare dates in UTC', () => {
  assert.equal(shortDate('2026-08-14 17:01:13.653421'), 'Aug 14, 2026');
  assert.equal(shortDate('2026-08-14'), 'Aug 14, 2026');
  assert.equal(shortDate('2026-08-14 23:59:59'), 'Aug 14, 2026'); // no TZ drift
  assert.equal(shortDate(null), '');
});

test('utcStamp renders exporter timestamps as minute-precision UTC', () => {
  assert.equal(utcStamp('2026-08-15 03:19:38.318811'), '2026-08-15 03:19 UTC');
  assert.equal(utcStamp(null), null);
  assert.equal(utcStamp('not a time'), null);
});

test('packageNoun follows the registry slug', () => {
  assert.equal(packageNoun('rubygems', 1), 'gem');
  assert.equal(packageNoun('rubygems', 2), 'gems');
  assert.equal(packageNoun('cratesio', 1), 'crate');
  assert.equal(packageNoun(undefined, 2), 'packages');
});

test('searchResultSummary keeps the registry name and sentence punctuation together', () => {
  assert.equal(searchResultSummary('rubygems', 'RubyGems.org', 12), '12 tracked gems matched in RubyGems.org.');
});

test('provenanceLabel names the signal per kind', () => {
  assert.equal(provenanceLabel('sigstore_attestation'), 'Sigstore');
  assert.equal(provenanceLabel('trustpub_metadata'), 'Trusted publisher');
  assert.equal(provenanceLabel('digital_attestation'), 'Digital attestation');
});

test('repositoryLabel shortens repository URLs for link text', () => {
  assert.equal(repositoryLabel('https://github.com/ruby/psych'), 'ruby/psych');
  assert.equal(repositoryLabel('https://github.com/ruby/psych.git'), 'ruby/psych');
  assert.equal(repositoryLabel('not a url'), 'not a url');
});
