# Seed data

These files are compact excerpts derived from the public data dumps the
registries publish. They are included so the tracker can be set up and
reproduced without downloading and processing the full dumps; each
directory's `manifest.json` records the exact dump its dataset was
distilled from.

- `rubygems/` — from the RubyGems.org weekly PostgreSQL dump
  (https://rubygems.org/pages/data), around 650 MB. The dump includes the
  attestations table, so provenance is seeded along with the versions. A
  weekly workflow discovers the current official archive, records its SHA-256,
  validates semantic invariants, and proposes changes from the fixed
  `automation/rubygems-seed` branch.
- `cratesio/` — from the crates.io daily database dump
  (https://static.crates.io/db-dump.tar.gz), around 1.8 GB. That dump
  carries no trusted-publishing metadata, so its versions are seeded
  unchecked and their provenance is established from the API instead. The
  workflow records the archive SHA-256 and proposes each newer exact source as
  a bot-opened PR from a fixed automation branch; publication follows only
  after a human reviews and merges it.

The repository's semantic checkers, not gzip bytes alone, define equality.
They validate manifests, freshness, exact package counts, deterministic ranks,
identifiers, references, timestamps, and registry-specific row contracts.
Compressed files use deterministic timestamps. Gzip container metadata does
not count as tracked-content drift, while a newer exact dump still advances its
manifest so the committed source never expires behind unchanged package rows.

The bot proposes a seed; a human merges it. The proposal workflow never calls
the merge API. See [`docs/operations.md`](../docs/operations.md) for the hosted
controls and their current limits.

Rights in the underlying registry records remain with their respective
owners and are governed by each registry's terms of service; rakkan does
not claim or grant any separate license over that data. The scripts that
produce these files (under `research/`) are covered by the repository's
code license.
