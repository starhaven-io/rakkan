# Agent Instructions for rakkan

rakkan is a public tracker for trusted publishing adoption across package
registries: which packages publish with verifiable provenance, adoption share
among the most-downloaded packages, and trends over time. RubyGems.org is the
first registry; the schema and ingestion pipeline are registry-agnostic and
crates.io is planned next. Prefer reading the Hanami v3.0 guides
(hanakai.org) or installed gem source over assuming framework APIs.

## Project overview

- **Stack:** two halves. The engine is headless Ruby (developed on 4.0.6):
  Hanami 3.0.1 as container/persistence (ROM/Sequel on SQLite) driving
  ingestion via rake tasks; it has no web server. `site/` is the public web
  tier: Astro SSR on Cloudflare Workers reading D1,
  fed by `rake export:d1`. D1 is SQLite, so the export reuses the engine
  schema verbatim; booleans are 1/0 integers and timestamps are UTC text.
- **Layout:** the engine's persistence lives in `app/` (relations, repos,
  structs; no web code); ingestion lives in `slices/ingestion/` (adapter
  interface, RubyGems adapter, sigstore attestation parsing, operations);
  engine entry points are rake tasks (`lib/tasks/`). The web tier is
  `site/src/` (pages, D1 query layer, middleware).
- **Data:** `seed/rubygems/` holds compact tracked-set data derived from the
  weekly rubygems.org PostgreSQL dump (`manifest.json` records which one).
  `research/` holds the dump-processing scripts and recorded registry
  samples. DATA_SOURCES.md is the evidence base for where the provenance
  signal lives.

## Commands

- `just check`: the common entry point. Engine specs, RuboCop, site unit
  tests, an Astro production build, plus optional typos.
- `bin/setup && just dev`: fresh-clone path to the running site on real
  data (engine deps, databases, seed, site deps, local D1; no network
  beyond package installs). Piecemeal equivalents live in the justfile
  (`seed`, `snapshot`, `export-d1`, `site-db`).
- Live-API tasks (`just discover`, `just refresh N`) hit rubygems.org.

## Safety constraints

- **Be a polite client.** All registry traffic must go through
  `Ingestion::HTTPClient` (identifying User-Agent, ~4 req/s against a
  documented 10 req/s limit, backoff honoring Retry-After, disk cache under
  `var/cache/`). Do not add raw HTTP calls elsewhere.
- **Never scrape registry HTML.** The provenance signal is fully available
  from JSON APIs and the public dumps (see DATA_SOURCES.md). The HTML-only
  "Pushed by" attribution is deliberately untracked.
- **The spec suite must stay offline.** Fixtures under `spec/fixtures/` are
  distilled from recorded data; `FakeHTTPClient` raises on unstubbed URLs.
  Never add specs that perform live network calls.
- Ingestion must remain idempotent and resumable: writes are upserts keyed
  on natural unique indexes, and provenance checks are dated
  (`provenance_checked_at`), including the dump-date stamp at seed time.

## Gotchas

- Zeitwerk inflects acronyms: `http_client.rb` must define `HTTPClient`.
- Projected relations (`select(...)`) yield plain hashes; auto-struct
  mapping happens at the repo boundary. Index with `row[:key]` in
  operations.
- `Dry::Operation` wraps `call` results in `Success(...)` even without the
  step DSL.
- Bulk writes intentionally drop to documented Sequel
  (`insert_conflict` + `multi_insert`); `Relation#dataset` is public ROM
  API, so leave these rather than reworking them into ROM DSL.
- A long-lived process (console, astro dev via the platform proxy) holds
  SQLite's old inode across `rm`; restart after rebuilding databases.
- Astro routes must set `export const prerender = false` or dynamic routes
  demand `getStaticPaths`; JSX collapses whitespace at expression
  boundaries, so spaces between adjacent expressions need `{' '}`.

## CI

Hosted CI runs the engine and site checks behind the org-required
`conclusion` aggregate (`.github/workflows/ci.yml`, repo-owned);
`just check` is the local equivalent and the required gate before any
change lands.

<!-- fleet:block commit-and-pr-conventions -->
<!-- fleet:end -->
