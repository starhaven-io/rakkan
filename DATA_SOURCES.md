# Data sources for trusted publishing adoption

Investigated 2026-08-14 and expanded for crates.io and PyPI on 2026-08-19.
Recorded samples live in `research/samples/`; distilled offline fixtures live
in `spec/fixtures/`; the scripts behind the dump-derived numbers live in
`research/`. RubyGems registry state referenced throughout is the weekly dump
dated 2026-08-10 plus live API probes on 2026-08-14. Evidence caveat: the probe
script retained response bodies only, so saved samples do not preserve status
codes or headers (statuses were observed at probe time), and the raw dump is
not retained; dump-derived claims are reproducible from a fresh dump via the
scripts, not from the committed artifacts alone.

## Summary and recommendation

The trusted publishing / provenance signal for RubyGems is **available from
public JSON APIs and from the weekly data dump**. No HTML scraping is needed
for any part of the pipeline. The recommended ingestion path is:

1. **Backfill + tracked set (weekly):** the official PostgreSQL dump. One
   ~650 MB download per week yields download counts (top-N definition), all
   versions, and the complete `attestations` table (11,926 rows covering
   11,920 distinct attested versions registry-wide as of 2026-08-10). COPY
   blocks are plain TSV, so a streaming parser suffices; no Postgres server
   required.
2. **Freshness (weekly post-dump):**
   `GET /api/v1/timeframe_versions.json` (7-day window, paginated) discovers
   new versions of tracked gems, then
   `GET /api/v1/attestations/<name>-<version>.json` checks each new version.
   The API updates continuously, but rakkan polls it after each weekly dump so
   observations share the dump cadence.
3. **Identity enrichment:** parse the Fulcio X.509 certificate inside each
   sigstore bundle (stdlib OpenSSL; extension OIDs `1.3.6.1.4.1.57264.1.*`)
   to get issuer, source repo, workflow, commit, and run URL.

Headline baseline from the 2026-08-10 dump: **96 of the top 1,000 gems by
downloads (9.6%) have at least one attested version**; 664 of their 104,587
indexed version rows are attested.

## RubyGems.org

### v1 gems / versions APIs: no signal

`/api/v1/gems/<name>.json` and `/api/v1/versions/<name>.json` (and the v2
per-version endpoint) return gemspec-derived data only. Verified on
`sigstore`, `rubocop`, `rack`: no provenance, attestation, or pushed-by
fields. Samples: `v1_gems_*.json`, `v1_versions_sigstore.json`,
`v2_version_sigstore-0.2.3.json`.

### v1 attestations API: the per-version signal

`GET /api/v1/attestations/<name>-<version>.json` is documented in the
official API guide and returns an array of sigstore bundles
(`application/vnd.dev.sigstore.bundle.v0.3+json`, `messageSignature` form;
a signed gem digest with a Fulcio certificate, not a DSSE/SLSA statement).
Unattested versions return `[]` with HTTP 200 (clean semantics, no 404
handling). Samples: `v1_attestations_sigstore-0.2.3.json` (populated),
`v1_attestations_rack-3.2.7.json` and `v1_attestations_rubocop-1.89.0.json`
(both empty; adoption is genuinely partial even among flagship gems).

The publisher identity is inside the certificate (`verificationMaterial.
certificate.rawBytes`, base64 DER). Decoding with stdlib OpenSSL yields, for
sigstore 0.2.3: issuer `https://token.actions.githubusercontent.com`, repo
`sigstore/sigstore-ruby`, workflow `release.yml@refs/tags/v0.2.3`, commit
SHA, run URL, `github-hosted` runner. These become real schema columns.

### Weekly PostgreSQL dump: the bulk signal and the top-N source

`rubygems.org/pages/data` → weekly sanitized dumps in the public
`rubygems-dumps` S3 bucket (`production/public_postgresql/<date>/
public_postgresql.tar`, ~650 MB; listing samples saved). The tar holds one
plain-format `PostgreSQL.sql.gz`; COPY blocks are TSV, parsed by streaming
(`research/extract_dump.rb`) without a Postgres install.

Tables present: `rubygems`, `versions`, `dependencies`, `gem_downloads`,
`linksets`, `deletions`, and, decisively, **`attestations`
(id, version_id, body, media_type, …)** with the full sigstore bundle in
`body`. So the dump carries the complete signal in bulk.

- **Top-N by downloads:** `gem_downloads` has per-version rows plus a
  `version_id=0` total row per gem. Sanity-checked on rack (total
  1,324,158,241 ≈ sum of per-version rows). `research/top_gems.rb` produces
  the top-1000 list; top of the list (bundler, aws-sdk-core, …) is plausible.
- **Sanitization caveat:** `users` and `api_keys` tables are absent, so
  `versions.pusher_id` / `versions.pusher_api_key_id` are dangling IDs. All
  664 attested tracked versions have `pusher_id NULL + pusher_api_key_id
  set`, consistent with trusted-publisher pushes, but the dump alone cannot
  attribute human pushers, and there is no `oidc_*` table to distinguish a
  plain-API-key push from a trusted-publisher push for unattested versions.

### timeframe_versions: the incremental feed

`GET /api/v1/timeframe_versions.json?from=…&to=…` (ISO8601, max 7-day span,
paginated) returns full version objects in ascending created_at order;
oldest first, pages disjoint (verified live with page=1 vs page=2 samples).
This is the polling source for "new versions since the last run"; the
ascending order is what lets an interrupted run park its cursor at the last
entry seen.

### HTML gem pages: richer, but not needed

The gem page (sample: `html_gem_page_sigstore.html`) shows "Pushed by"
(human account for rack; `GitHub Actions repo@workflow` for sigstore) and a
Provenance panel. Two things are HTML-only: the human pusher attribution and
the trusted-publisher badge for **unattested** TP pushes. The provenance
panel content itself is reconstructible from the attestations API. Decision:
**do not scrape**; track attestation presence as the (lower-bound) adoption
signal and note the nuance in the UI copy.

### Rate limits

Documented: 10 req/s for API and site, `Retry-After` on 429, stricter
rack-attack limits on auth-ish endpoints (not relevant here). Client policy
adopted: identifying User-Agent, ≤4 req/s, exponential backoff on 429/5xx,
on-disk response cache (feed pages are served from cache on rerun;
provenance checks deliberately bypass cache reads to observe current
state).

## deps.dev (corroborating source)

`GET https://api.deps.dev/v3/systems/RUBYGEMS/packages/<name>/versions/<v>`
returns `attestations[]` with `verified: true`, `sourceRepository`, `commit`,
and a URL pointing back to the rubygems.org attestations API (sample saved).
Useful as a cross-check or to skip cert parsing, but it adds a third-party
dependency, has no download counts, and its freshness lag is unknown, so it
is not on the primary path.

## crates.io

- `GET /api/v1/crates/<crate>/<version>` version objects carry
  **`published_by`** (human user object) and **`trustpub_data`**. For
  cargo-semver-checks 0.50.0: `{provider: "github", repository:
  "obi1kenobi/cargo-semver-checks", run_id, sha}` with `published_by: null`.
  serde 1.0.228: `published_by` set, `trustpub_data: null`. So crates.io
  exposes trusted publishing directly in JSON; no cert parsing, and unlike
  RubyGems it also names the human pusher in the API.
- `GET /api/v1/crates/<crate>/versions` returns those same version objects in
  a batch. A 2026-08-23 live probe returned all 316 serde versions with
  `meta.total: 316` and `meta.next_page: null`; the distilled trusted/plain
  response is `spec/fixtures/api/cratesio_versions.json`. Completeness is not
  assumed: the adapter falls back to the per-version endpoint for any selected
  number absent from a batch response.
- [crates.io documents `trustpub_data` as
  unstable](https://github.com/rust-lang/crates.io/blob/main/crates/crates_io_api_types/src/lib.rs).
  The adapter therefore maps only the small provider/repository/run/SHA shape
  evidenced in the recorded samples and does not persist the raw object as a
  stable contract.
- The daily database dump at `static.crates.io/db-dump.tar.gz` was inspected
  on 2026-08-20. Its metadata identifies the cut time and crates.io source
  commit; `crate_downloads.csv`, `crates.csv`, `default_versions.csv`, and
  `versions.csv` are sufficient to reproduce a total-download top 1,000 and
  its version history. The export does not include `trustpub_data`, trusted
  publisher configuration, or token records, so it is not evidence that an
  unattested version was checked for provenance.
- The [official data-access policy](https://crates.io/data-access) prefers the
  index or daily dump for bulk access and caps API clients at one request per
  second with an identifying User-Agent. `Ingestion::HTTPClient` enforces that
  host-specific interval; provenance checks bypass cache reads so a later
  trusted publication cannot remain hidden behind a cached negative response.
- `research/download_cratesio_dump.rb` streams the official archive through
  `Ingestion::HTTPClient`, preserving its identifying User-Agent, throttle, and
  retry policy without buffering the dump in memory. The client follows the
  official endpoint's allowlisted HTTPS redirect to crates.io's CDN.
  `research/build_cratesio_seed.rb` then performs the ranking and version
  distillation, and `seed/cratesio/` holds its top-1,000 output. Rebuilding from
  the same dump on the same toolchain reproduces those files byte for byte;
  across toolchains the guarantee is the decompressed content, since the gzip
  container records a platform code. A Monday workflow compares that semantic
  content with the committed seed and updates an automation branch only when it
  changes. The dump is daily, so this reviewed weekly re-seeding is also the
  registry's discovery path and no live feed walk is needed.
- A top-1,000 backfill is bounded by publish date rather than by crawling
  every version. `trustpub_data` arrived in the
  `2025-07-04-102806_add_trustpub_data_columns` migration and records how a
  version was published, so it is never backfilled: a version created before
  that date provably carries none, and settling it needs no request. On a
  RubyGems-sized tracked set (106,150 versions) that is the difference between
  roughly 30 hours of crawling at the documented 1 req/s and a few hours.
- GitLab trusted publishing followed in the
  `2025-09-24-104418_add_trustpub_configs_gitlab` migration, so `provider` is
  not always `github` in live data and the adapter maps both.

## PyPI

- The [release JSON API](https://docs.pypi.org/api/json/) lists the filenames
  belonging to one release at `GET /pypi/<project>/<version>/json`. PyPI's
  [Integrity API](https://docs.pypi.org/api/integrity/) then serves PEP 740
  provenance per file through this route:
  `GET /integrity/<project>/<version>/<filename>/provenance`. It uses
  `application/vnd.pypi.integrity.v1+json`; 404 means that file has no
  provenance.
- A provenance object groups attestations by Trusted Publisher identity. Its
  `publisher` object exposes the provider plus provider-specific repository and
  workflow fields. The adapter aggregates every distribution in a release,
  chooses a deterministic identity when files disagree, and records the total
  attestation count. It records registry-accepted provenance presence and does
  not independently re-verify the signatures.
- PyPI's public BigQuery [`file_downloads`
  dataset](https://docs.pypi.org/api/bigquery/) is the official bulk source for
  a download-ranked tracked set; `distribution_metadata` is the corresponding
  immutable release-metadata table. The JSON [Index
  API](https://docs.pypi.org/api/index-api/) provides every available file,
  version, upload time, and yank state for one project.
- `research/pypi_top_packages.sql` fixes the tracked-set definition at the top
  1,000 normalized projects by pip downloads over the 30 complete UTC days
  ending at an explicit `as_of` date. Restricting the installer to pip excludes
  known mirror traffic such as bandersnatch; the end-exclusive parameter and
  deterministic name tie-break make the ranking reproducible rather than
  dependent on query run time.
- The [API guidance](https://docs.pypi.org/api/) prefers RSS for periodic
  release polling, but the global updates feed is a bounded latest-items view,
  not a durable cursor: [Warehouse limits it to 100
  releases](https://github.com/pypi/warehouse/blob/main/warehouse/rss/views.py),
  and a live 2026-08-20 observation covered only about 18 minutes. It cannot
  safely bridge a daily ingestion interval by itself. A durable discovery
  cursor still needs to be fixed and recorded before ingestion is enabled.
- The implemented adapter is therefore provenance-only. Its per-file Integrity
  API calls are suitable for fresh releases after discovery, not for a blind
  historical backfill across every release of the top 1,000 projects.

## Schema implications

Three provenance shapes must coexist:

| | RubyGems | crates.io | PyPI |
| --- | --- | --- | --- |
| Signal | sigstore attestation presence (lower bound of TP) | `trustpub_data` on the version (direct) | PEP 740 provenance on a release file |
| Identity | parsed from Fulcio cert extensions | plain JSON fields | Trusted Publisher fields in the provenance object |
| Human pusher | HTML-only (not tracked) | `published_by` in API | not exposed by the provenance API |

So `package_versions` gets a nullable provenance block sourced from any of
these shapes: `provenance_kind` (for example, `sigstore_attestation`,
`trustpub_metadata`, or `digital_attestation`),
`provenance_provider` (issuer/provider), `source_repository`, `workflow_ref`,
`commit_sha`, `run_url`, `attestation_count`. (An early sketch also called
for a raw-JSON column; the implemented schema stores only the parsed
identity; raw bundles remain fetchable from the registry.) Adoption stats
count "versions with provenance" and "packages with ≥1 provenant version",
which mean the same thing across all three registries.
