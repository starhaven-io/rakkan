# Rakkan

<!-- fleet:block badges -->

[![CI](https://github.com/starhaven-io/rakkan/actions/workflows/ci.yml/badge.svg)](https://github.com/starhaven-io/rakkan/actions/workflows/ci.yml)
[![License: AGPL-3.0-only](https://img.shields.io/badge/License-AGPL--3.0--only-blue.svg)](LICENSE)

<!-- fleet:end -->

A public tracker for trusted publishing adoption across package registries:
which packages publish with registry-accepted provenance, what share of the
most-downloaded packages have adopted it, and how that changes over time.

RubyGems.org is the first production registry. The schema and ingestion
pipeline are registry-agnostic: crates.io carries its tracked set in
`seed/cratesio/`, reads provenance from the API, and is exposed by the web
tier. Weekly workflows propose both production tracked-set refreshes as
reviewed pull requests. PyPI reads provenance, while its tracked set and
durable discovery cursor are not implemented. The ingestion
engine is built with [Hanami 3.0.2](https://hanakai.org/hanami).

Where the provenance signal actually lives, with recorded evidence, is
documented in [DATA_SOURCES.md](DATA_SOURCES.md). Headline: for RubyGems it
is fully available from public JSON APIs and the weekly data dump; no HTML
scraping anywhere in this codebase.

A note on trust: rakkan records attestation *presence* and parses the
publisher identity out of each bundle's Fulcio certificate. It does not
re-verify sigstore signatures; RubyGems.org verifies every uploaded bundle
against the gem and a trusted-publisher identity at push time, and rakkan
deliberately treats the registry's verification as authoritative (deps.dev
independently reports these attestations as verified). Counts here are
therefore "attestations the registry accepted", not an independent audit.
The rationale is recorded in
[ADR 0001](docs/adr/0001-registry-accepted-provenance.md).

## Running it

Two halves: a headless Ruby ingestion engine (Ruby ≥ 3.3 per the locked gems;
developed on 4.0.6, pinned in `.ruby-version`) and a web tier under `site/`
(Astro on Cloudflare Workers reading D1; Node ≥ 26). One command sets up both
from a fresh clone: engine dependencies, databases, committed dump-derived
seed data, site dependencies, and the local D1:

```sh
bin/setup
```

Then start the site at http://localhost:4321:

```sh
just dev
```

The equivalent manual steps, when you want them piecemeal: `bundle
install`, `cp .env.example .env`, `bundle exec hanami db prepare`,
`bundle exec rake ingest:seed`, `bundle exec rake "ingest:seed[cratesio]"`,
`bundle exec rake snapshot:take`, then `just install-site`, and finally `just
site-db` to export and load the local D1. The local crates.io tracked set is
available immediately, but its overview remains unsnapshotted until the live
provenance refresh completes.

## Keeping it fresh

```sh
bundle exec rake ingest:discover      # find versions published since the seed dump
bundle exec rake "ingest:refresh[50]" # check up to N ordinary versions plus waiver probes
bundle exec rake snapshot:take        # record the current adoption stats
```

Live traffic goes through one polite client: an identifying User-Agent,
registry-specific rate limits, bounded responses and retries, `Retry-After`
support, and atomic disk caching under `var/cache/`. Discovery can reuse cached
feed pages; provenance checks bypass cache reads so they observe current state.
Unwaived unexpected 404s, malformed JSON, incomplete pages, and non-progressing cursors
fail closed without stamping a negative provenance check.

The tracked-set workflows run each Monday:

- `Update RubyGems seed` discovers the newest official weekly PostgreSQL dump,
  verifies its listed size and SHA-256, parses named COPY columns, and rebuilds
  the top 1,000 with its versions and attestations.
- `Update crates.io seed` streams the official daily database dump and rebuilds
  the top 1,000 with its version history. The dump has no provenance signal,
  so provenance remains an API refresh.

Both workflows reject stale, future-dated, truncated, incorrectly ranked, duplicate, or
referentially invalid data. A rerun against the exact current dump succeeds as
a no-op; an older dump or reused timestamp with different content fails. They
compare compressed files by semantic content, then update a fixed automation
branch and open a seed-only pull request. Source workflows cannot approve or
merge that pull request. If the same candidate is already present in the one
open same-repository automation pull request, the workflow leaves its head,
body, and approval state untouched. The pull-request diff may be a nonempty
subset of the expected files but must include the manifest; the full candidate
tree is compared byte-for-byte, and any unexpected file fails closed. A post-merge listener
rechecks its repository, base, branch, complete file set, and immutable merge
SHA before dispatching the
protected all-registry refresh. It verifies that merge remains an ancestor of
current `main`, authorizes one exact current SHA, waits for the refresh result,
and retries a dispatch cancelled or skipped outside the production queue. The
shared production lock retains up to 100 pending deploys, refreshes, and
rollbacks instead of silently replacing an earlier pending run. Each seed
listener requests both registries, and a run waiting for protected-environment
approval remains authoritative after the listener's bounded wait. A human merges
every seed pull request; hosted rulesets, not repository text, decide whether an
approval is required as well.

`Refresh Data` restores production history into a fresh engine database,
validates the committed seed is no more than nine days old, performs resumable
ingestion within a bounded wall-clock budget, and snapshots only a complete
observation. RubyGems discovery must drain. An incomplete crates.io backfill
or RubyGems provenance refresh persists progress but withholds its snapshot.
Yanked versions require no provenance lookup. A persistent exact per-version
404 can be handled only by an expiring, source-controlled waiver; it is neither
stamped nor counted as a negative provenance observation. At most 100 reviewed
waivers are allowed, and their exact versions are probed separately so they
cannot consume or starve the ordinary refresh limit. An expired entry is
reported and becomes inactive, so its exact version returns to the ordinary
fail-closed error path without stopping unrelated registries.
The refresh wrapper freezes one UTC run date for waiver evaluation and the
resulting snapshot, even if its subprocesses cross midnight. Snapshot dates
therefore describe the day on which the complete refresh began, and a delayed
seed merge cannot rewrite an older dump-dated history point.

Before production D1 is replaced, the workflow captures a D1 Time Travel
bookmark and uploads it with a checksum-bound recovery manifest and full SQL
export for evidence. It then requires the deployed Worker's health contract to
accept the candidate schema, and
requires remote schema and exact row counts to match the local export. Worker
deployment, D1 replacement, and rollback share a serialization lock.
Push-triggered refresh dry runs use a fresh local database and receive no
Cloudflare environment or token. Site deployment is separate and performs a
read-only D1 schema-contract check while holding the production transition
lock before deploying the Worker, then verifies that the deployed health
endpoint advertises the expected compatibility set. Every pre-deploy and
post-deploy health check requires a successful response. The legacy one-column
export marker remains readable as schema 1 for the documented recovery window.
The Worker also exposes a D1-independent compatibility route so rollback can
validate reader support even when the current database is unhealthy.

The measurable freshness contract is in
[docs/data-freshness.md](docs/data-freshness.md). Hosted setup, schema rollout,
rollback, and incident procedures are in
[docs/operations.md](docs/operations.md).

## Tests

Run the repository gate:

```sh
just check-tools
just check
```

It enforces structural and semantic seed validity without making unrelated CI
expire as the wall clock advances. Protected refreshes and seed updaters retain
the freshness gates. The command also enforces engine line/branch and
TypeScript line/branch/function/statement
coverage thresholds, Ruby and site tests, RuboCop, ShellCheck, Prettier, Astro
type checking and production build, npm install-script policy, actionlint,
zizmor, pinprick, and spelling. The test suites make no network calls: fixtures
under `spec/fixtures/` are distilled from dump-derived seeds and recorded
registry responses. Hosted dependency, CodeQL, and Codecov jobs remain hosted
evidence and are not implied by the local gate.

`just check-tools` reports missing machine-wide audit executables with their
Homebrew package names. `bin/setup` installs project dependencies, not those
global tools; see [CONTRIBUTING.md](CONTRIBUTING.md) for the fresh-clone path.

## Layout

- `app/`: the engine's persistence layer (relations, repos, structs)
- `site/`: the public web tier: Astro SSR on Cloudflare Workers reading
  the D1 export
- `slices/ingestion/`: registry adapter interface, RubyGems ingestion,
  crates.io and PyPI provenance adapters, sigstore attestation parsing, and
  the ingest/snapshot operations
- `seed/rubygems/`: compact tracked-set data derived from the exact weekly dump
  recorded in its `manifest.json`
- `seed/cratesio/`: compact tracked-set data derived from the exact daily dump
  recorded in its `manifest.json`; new versions remain unchecked until refresh
- `research/`: the dump-processing scripts and recorded registry samples

## Project documentation

- [Architecture and trust boundaries](docs/architecture.md)
- [Data-source evidence](DATA_SOURCES.md)
- [Operations, rollback, and incident response](docs/operations.md)
- [Security policy](SECURITY.md)
- [Contributing](CONTRIBUTING.md) and [code of conduct](CODE_OF_CONDUCT.md)

<!-- fleet:block license-section -->

## License

Code is licensed [AGPL-3.0-only](LICENSE). The files under `seed/` are
excerpts derived from the public data dumps published by the
registries rakkan tracks, included for reproducibility; rights in the
underlying records remain with their owners under each registry's
terms, and rakkan claims no separate license over them (see
[seed/README.md](seed/README.md)).

<!-- fleet:end -->
