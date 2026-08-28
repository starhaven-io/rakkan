# Agent Instructions for rakkan

rakkan is a public tracker for trusted publishing adoption across package
registries: which packages publish with verifiable provenance, adoption share
among the most-downloaded packages, and trends over time. RubyGems.org is the
first production registry; the schema and ingestion pipeline are
registry-agnostic. crates.io has its tracked set committed in
`seed/cratesio/`, reads provenance from the API, has completed its initial
production backfill, and is available in the web tier. A weekly workflow
regenerates its tracked set on an automation branch; a bot-opened,
human-reviewed seed PR must merge before the protected production refresh is dispatched.
PyPI is still provenance-only and needs both a tracked set and a durable
discovery cursor.
Prefer reading the Hanami v3.0 guides (hanakai.org) or installed gem source
over assuming framework APIs.

## Project overview

- **Stack:** two halves. The engine is headless Ruby (developed on 4.0.6):
  Hanami 3.0.1 as container/persistence (ROM/Sequel on SQLite) driving
  ingestion via rake tasks; it has no web server. `site/` is the public web
  tier: Astro SSR on Cloudflare Workers reading D1,
  fed by `rake export:d1`. D1 is SQLite, so the export reuses the engine
  schema verbatim; booleans are 1/0 integers and timestamps are UTC text.
- **Layout:** the engine's persistence lives in `app/` (relations, repos,
  structs; no web code); ingestion lives in `slices/ingestion/` (adapter
  interface, RubyGems ingestion, crates.io and PyPI provenance adapters,
  sigstore attestation parsing, operations);
  engine entry points are rake tasks (`lib/tasks/`). The web tier is
  `site/src/` (pages, D1 query layer, middleware).
- **Data:** `seed/rubygems/` and `seed/cratesio/` hold compact tracked-set
  data derived from their registries' weekly and daily public dumps;
  `manifest.json` records the exact source for each. `research/` holds the
  dump-processing scripts and recorded registry samples. DATA_SOURCES.md is
  the evidence base for where the provenance signal lives.

## Commands

- `just check`: the common entry point. Engine specs, RuboCop, site unit
  tests, an Astro production build, plus optional typos.
- `bin/setup && just dev`: fresh-clone path to the running site on real
  data (engine deps, databases, seed, site deps, local D1; no network
  beyond package installs). Piecemeal equivalents live in the justfile
  (`seed`, `snapshot`, `export-d1`, `site-db`).
- Live-API tasks default to rubygems.org; their registry argument selects
  another adapter where that operation is supported (`just refresh 50 cratesio`).

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
- A long-lived process (console, Astro dev through the Cloudflare Vite plugin) holds
  SQLite's old inode across `rm`; restart after rebuilding databases.
- Astro routes must set `export const prerender = false` or dynamic routes
  demand `getStaticPaths`. Astro preserves source whitespace around
  expressions, and HTML collapses line breaks to spaces; keep punctuation in
  the same expression or formatter string when it must remain attached.

## CI

Hosted CI runs the engine and site checks behind the org-required
`conclusion` aggregate (`.github/workflows/ci.yml`, repo-owned);
`just check` is the local equivalent and the required gate before any
change lands.

<!-- fleet:block commit-and-pr-conventions -->

## Commit and PR conventions

- Conventional Commits: `type(scope): description`. Valid types: `feat`,
  `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`.
  Mark a breaking change with `!` before the colon (`feat!:`,
  `feat(scope)!:`).
- Commits require DCO sign-off. Make all commits with `git commit -s` (enforced
  by the `.githooks/commit-msg` hook; run `just install-hooks` once per clone).
- Do not identify an AI tool or model as an author, co-author, committer, or
  signatory of a commit. Do not name an AI tool or model in `Co-authored-by`,
  `Assisted-by`, `Co-developed-by`, `Generated-by`, or similar trailers. Human
  `Co-authored-by` trailers are allowed.
- Never commit directly to `main`; create a feature branch and open a PR.
- PR descriptions should contain a concise summary of changes. Do not add a
  standalone test-plan section or checklists.
- When AI/LLM was used to generate or assist with a pull request, the initial
  PR description must end with exactly one unformatted line as the last line of
  the PR body: `AI disclosure: <model> with <how the output was verified>.`
  This is PR body text, not a commit trailer. Omit the line when no AI/LLM was
  used.
- Name the model as its vendor names it, for example `Claude Opus 5`. Do not
  also name a tool or harness unless the harness is the only identifier. Do not
  describe what the AI did.
- Do not format the disclosure as a heading, bullet, bold label, or horizontal
  rule, and do not add a promotional "generated with" footer.
- Keep each prose paragraph in a PR description on one source line. Do not
  hard-wrap PR body prose like a commit message; preserve intentional Markdown
  line breaks in lists, code blocks, and other structured content.
- Comments must earn their keep: a comment states a constraint or rationale the
  code cannot express. Never add comments that narrate what the code does,
  restate names, or explain a change to its reviewer.

<!-- fleet:end -->
