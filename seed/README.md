# Seed data

These files are compact excerpts derived from the public data dumps the
registries publish. They are included so the tracker can be set up and
reproduced without downloading and processing the full dumps; each
directory's `manifest.json` records the exact dump its dataset was
distilled from.

- `rubygems/` — from the RubyGems.org weekly PostgreSQL dump
  (https://rubygems.org/pages/data), around 650 MB. The dump includes the
  attestations table, so provenance is seeded along with the versions.
- `cratesio/` — from the crates.io daily database dump
  (https://static.crates.io/db-dump.tar.gz), around 1.8 GB. That dump
  carries no trusted-publishing metadata, so its versions are seeded
  unchecked and their provenance is established from the API instead. A
  weekly workflow proposes semantic seed changes on a fixed automation branch;
  publication follows only after a human opens, reviews, and merges that PR.

Rights in the underlying registry records remain with their respective
owners and are governed by each registry's terms of service; rakkan does
not claim or grant any separate license over that data. The scripts that
produce these files (under `research/`) are covered by the repository's
code license.
