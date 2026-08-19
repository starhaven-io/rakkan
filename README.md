# Rakkan

<!-- fleet:block badges -->

[![CI](https://github.com/starhaven-io/rakkan/actions/workflows/ci.yml/badge.svg)](https://github.com/starhaven-io/rakkan/actions/workflows/ci.yml)
[![License: AGPL-3.0-only](https://img.shields.io/badge/License-AGPL--3.0--only-blue.svg)](LICENSE)

<!-- fleet:end -->

A public tracker for trusted publishing adoption across package registries:
which packages publish with verifiable provenance, what share of the
most-downloaded packages have adopted it, and how that changes over time.

RubyGems.org is the first registry. The schema and ingestion pipeline are
registry-agnostic; crates.io is next. The ingestion engine is built with
[Hanami 3.0](https://hanakai.org/hanami).

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
bundle exec rake snapshot:take        # record today's adoption stats
```

Both live tasks go through a polite client: identifying User-Agent, ~4
requests/second (rubygems.org documents 10 rps), exponential backoff
honoring Retry-After, and an on-disk cache under `var/cache/`. Discovery
reruns serve already-seen feed pages from that cache; provenance checks
deliberately bypass the read side of the cache so they observe current
registry state. Everything is idempotent; running twice converges.

The two data sources run on different cadences, deliberately:

- **Daily (live APIs):** discovery pulls newly published versions from the
  registry's feed, refresh checks their attestations, and the snapshot
  records that day's adoption. Day-over-day movement on the site comes
  entirely from this path; the dump is not involved.
- **Weekly (public dump):** RubyGems.org publishes its dump weekly, so the
  tracked set itself (the top-1,000 ranking and download counts) is
  re-derived on that cadence with the scripts under `research/`
  (`extract_dump.rb` → `top_gems.rb` → `filter_versions.rb` →
  `build_seed.rb`), and packages that fell out of the top 1,000 are
  untracked. Between dumps the denominator intentionally holds still.

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
- `slices/ingestion/`: registry adapter interface, the RubyGems adapter,
  sigstore attestation parsing, and the ingest/snapshot operations
- `seed/rubygems/`: compact tracked-set data derived from the 2026-08-10
  weekly dump (see `manifest.json`)
- `research/`: the dump-processing scripts and recorded registry samples

<!-- fleet:block license-section -->

## License

Code is licensed [AGPL-3.0-only](LICENSE). The files under `seed/` are
excerpts derived from the
[RubyGems.org public data dumps](https://rubygems.org/pages/data),
included for reproducibility; rights in the underlying records remain
with their owners under RubyGems.org's terms, and rakkan claims no
separate license over them (see [seed/README.md](seed/README.md)).

<!-- fleet:end -->
