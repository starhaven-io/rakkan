import assert from 'node:assert/strict';
import { test } from 'node:test';

import { REGISTRY_SLUGS, registrySite, registrySlugForPath } from '../src/lib/registries.ts';

test('registry route families preserve RubyGems URLs and scope crates.io URLs', () => {
  const rubygems = registrySite('rubygems');
  const cratesio = registrySite('cratesio');

  assert.deepEqual(REGISTRY_SLUGS, ['rubygems', 'cratesio']);
  assert.deepEqual(
    [rubygems.overviewPath, rubygems.packagesPath, rubygems.searchPath, rubygems.packagePath('rack')],
    ['/', '/packages', '/search', '/packages/rack'],
  );
  assert.deepEqual(
    [cratesio.overviewPath, cratesio.packagesPath, cratesio.searchPath, cratesio.packagePath('serde')],
    ['/cratesio', '/cratesio/packages', '/cratesio/search', '/cratesio/packages/serde'],
  );
});

test('internal and registry package links encode package names', () => {
  const rubygems = registrySite('rubygems');
  const cratesio = registrySite('cratesio');

  assert.equal(rubygems.packagePath('name with/slash'), '/packages/name%20with%2Fslash');
  assert.equal(rubygems.packageUrl('name with/slash'), 'https://rubygems.org/gems/name%20with%2Fslash');
  assert.equal(cratesio.packagePath('name with/slash'), '/cratesio/packages/name%20with%2Fslash');
  assert.equal(cratesio.packageUrl('name with/slash'), 'https://crates.io/crates/name%20with%2Fslash');
});

test('registry-specific explanations describe the provenance signal and observation cadence', () => {
  const rubygems = registrySite('rubygems');
  const cratesio = registrySite('cratesio');

  assert.match(rubygems.adoptionDescription('gem'), /lower bound/);
  assert.match(rubygems.historyDescription, /weekly dump/);
  assert.match(rubygems.releaseDescription, /Certificate-derived/);

  assert.match(cratesio.adoptionDescription('crate'), /trusted-publisher metadata/);
  assert.match(cratesio.historyDescription, /crates\.io dump/);
  assert.match(cratesio.releaseDescription, /Trusted-publisher metadata/);
});

test('only the crates.io path segment selects crates.io context', () => {
  assert.equal(registrySlugForPath('/cratesio'), 'cratesio');
  assert.equal(registrySlugForPath('/cratesio/packages/serde'), 'cratesio');
  assert.equal(registrySlugForPath('/cratesioevil'), 'rubygems');
  assert.equal(registrySlugForPath('/packages/rack'), 'rubygems');
});
