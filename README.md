# Rakkan

<!-- fleet:block badges -->

[![CI](https://github.com/starhaven-io/rakkan/actions/workflows/ci.yml/badge.svg)](https://github.com/starhaven-io/rakkan/actions/workflows/ci.yml)
[![License: AGPL-3.0-only](https://img.shields.io/badge/License-AGPL--3.0--only-blue.svg)](LICENSE)

<!-- fleet:end -->

A public tracker for trusted publishing adoption across package registries:
which packages publish with verifiable provenance, what share of the
most-downloaded packages have adopted it, and how that changes over time.

RubyGems.org is the first production registry. The schema and ingestion
pipeline are registry-agnostic: crates.io carries its tracked set in
`seed/cratesio/`, reads provenance from the API, has completed its initial
production backfill, and is exposed by the web tier. Automating crates.io seed
regeneration remains to do, and PyPI reads provenance while its tracked set
and discovery cursor remain the next implementation phase. The ingestion
engine is built with [Hanami 3.0](https://hanakai.org/hanami).

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

## Running it

Two halves: a headless Ruby ingestion engine (Ruby ≥ 3.3 per the locked
gems; developed on 4.0.6, pinned in `.ruby-version`) and a web tier under
`site/` (Astro on Cloudflare Workers reading D1; Node ≥ 26). One command sets up both from a fresh clone: engine
deps, databases, seed data (committed, dump-derived; no network), site
deps, and the local D1:

```sh
bin/setup
```

Then start the site at http://localhost:4321:

```sh
just dev
```

The equivalent manual steps, when you want them piecemeal: `bundle
install`, `cp .env.example .env`, `bundle exec hanami db prepare`,
`bundle exec rake ingest:seed`, `bundle exec rake snapshot:take`, then
`just install-site`, and finally `just site-db` to export and load the
local D1.

## Keeping it fresh (live API tasks)

```sh
bundle exec rake ingest:discover      # find versions published since the seed dump
bundle exec rake "ingest:refresh[50]" # check provenance for up to N unchecked versions
bundle exec rake snapshot:take        # record the current adoption stats
```

Both live tasks go through a polite client: identifying User-Agent, ~4
requests/second (rubygems.org documents 10 rps), exponential backoff
honoring Retry-After, and an on-disk cache under `var/cache/`. Discovery
reruns serve already-seen feed pages from that cache; provenance checks
deliberately bypass the read side of the cache so they observe current
registry state. Everything is idempotent; running twice converges. If
discovery exhausts its page budget, it fails after persisting its cursor so
production cannot publish a partial observation. The workflow retries from
that cursor up to three times in the same database before failing the run.

The inputs update at different cadences, but production observations align to
RubyGems.org's weekly dump:

- **Weekly (public dump):** RubyGems.org publishes its dump weekly, so the
  tracked set itself (the top-1,000 ranking and download counts) is
  re-derived on that cadence with the scripts under `research/`
  (`extract_dump.rb` → `top_gems.rb` → `filter_versions.rb` →
  `build_seed.rb`), and packages that fell out of the top 1,000 are
  untracked. Between dumps the denominator intentionally holds still.
- **Post-dump (live APIs):** discovery pulls newly published versions from the
  registry's feed and refresh checks their attestations once per week. The
  resulting observation is dated to the Monday dump so the series has one
  comparable point per dump rather than flat daily entries.

The `Refresh Data` workflow runs at 06:17 UTC each Tuesday, after the Monday
dump, against a fresh engine database restored from production D1. It replaces
D1 only after ingestion, snapshotting, weekly history normalization, and export
all succeed. Changes under `site/` deploy separately through the `Deploy Site`
workflow; site deploys do not rewrite data.

Pushes that change the refresh workflow, database schema, normalization, or the
RubyGems seed run the same ingestion and export path as a dry run. They never
replace production D1 or change production refresh-issue state; publication is
limited to scheduled and explicitly dispatched runs.

The same workflow is the crates.io refresh entry point. The initial production
backfill completed against the 2026-08-21 dump. After committing a regenerated
crates.io seed, dispatch with `registry=cratesio` and `refresh_limit=1000`, then
repeat until the job summary reports zero tracked versions unchecked. Each run
restores the prior D1 state, re-seeds idempotently from the committed crates.io
dump, settles releases from before trusted publishing existed without API
calls, and persists the next bounded batch. It records a crates.io snapshot
only after the refresh is complete, so a partial observation is not presented
as an adoption point. The snapshot is dated to the committed dump rather than
the dispatch, so rerunning an unchanged seed replaces that observation instead
of adding a flat point on an arbitrary day.
Refresh retries share a 30-minute wall-clock budget, and the engine reports the
authoritative remaining backlog from the same scope it uses to select work.

Schema changes that site queries depend on must land before the corresponding
site change: merge the schema, dispatch `Refresh Data`, then merge the site
query. Push runs are deliberately dry runs and cannot order those production
deployments automatically.

## Tests

```sh
bundle exec rspec
```

The suite makes no network calls: fixtures under `spec/fixtures/` are
distilled from the real dump-derived seeds plus recorded registry
responses (see `research/`).

## Layout

- `app/`: the engine's persistence layer (relations, repos, structs)
- `site/`: the public web tier: Astro SSR on Cloudflare Workers reading
  the D1 export
- `slices/ingestion/`: registry adapter interface, RubyGems ingestion,
  crates.io and PyPI provenance adapters, sigstore attestation parsing, and
  the ingest/snapshot operations
- `seed/rubygems/`: compact tracked-set data derived from the 2026-08-10
  weekly dump (see `manifest.json`)
- `seed/cratesio/`: compact tracked-set data derived from the 2026-08-21
  daily dump; its versions remain unchecked until the provenance backfill
- `research/`: the dump-processing scripts and recorded registry samples

<!-- fleet:block license-section -->

## License

Code is licensed [AGPL-3.0-only](LICENSE). The files under `seed/` are
excerpts derived from the public data dumps published by the
registries rakkan tracks, included for reproducibility; rights in the
underlying records remain with their owners under each registry's
terms, and rakkan claims no separate license over them (see
[seed/README.md](seed/README.md)).

<!-- fleet:end -->
