# Architecture

Rakkan has a headless ingestion engine and a separately deployed read-only web
tier. SQLite is the interchange format between them.

```text
Official registry dumps ─┐
Registry JSON APIs ──────┼─> Ruby ingestion engine ─> SQLite ─> deterministic D1 export
Committed seed data ─────┘                                      │
                                                               v
                                      Cloudflare D1 <─ Astro Worker <─ public requests
```

## Engine

Hanami provides dependency injection and persistence wiring. ROM repositories
under `app/` own ordinary reads and writes. Registry adapters and operations
under `slices/ingestion/` own discovery, provenance refresh, seed ingestion,
and snapshots. Rake tasks under `lib/tasks/` are the supported entry points.

The core tables are:

- `registries`, including the durable discovery cursor
- `packages`, including the current tracked-set membership and rank
- `package_versions`, including dated provenance checks and parsed identity
- `adoption_snapshots`, uniquely keyed by registry and observation date

Natural unique indexes make repeated seed, discovery, and refresh runs
converge. A run can persist a bounded cursor without publishing an incomplete
adoption snapshot.

## Registry boundary

All live registry access uses `Ingestion::HTTPClient`. Adapters construct their
requests from fixed HTTPS API origins and escaped path or query values; the
client rejects plaintext, credential-bearing, and nonstandard-port URLs. It
identifies rakkan, enforces per-host pacing, honors `Retry-After`, bounds
retries and JSON response sizes, and atomically caches eligible feed
responses. A missing or malformed response is an error unless a specific
registry contract documents absence as meaningful, such as a PyPI Integrity
API 404. A reviewed exact version waiver can keep a persistent 404 from
blocking publication, but it remains an unknown observation rather than a
negative one. The waiver document accepts at most 100 entries; those exact
versions are probed outside the ordinary per-run limit so exceptions cannot
starve normal provenance work. Expired entries are inactive and therefore
cannot suppress errors or snapshot counts.

Seed builders consume official dumps without a registry database server. They
identify COPY or CSV columns by name, validate row widths and relationships,
produce deterministic files, and record the exact source in `manifest.json`.
Semantic checkers reject stale or inconsistent candidates before they reach an
automation branch.

## Export and web tier

`rake export:d1` reads the engine database in one transaction and atomically
writes schema plus data in foreign-key order. The export adds `export_meta`
with a generation timestamp and the version from `site/schema-contract.json`,
plus a checksum-bound metadata sidecar containing that identity and exact table
counts for publication readback.

The Astro Worker reads D1 but never writes it. The middleware checks the schema
contract before serving an edge-cached generation. A mismatch is fatal, not a
stale-cache fallback. A marker temporarily absent during replacement can use a
warm isolate's last accepted generation, but an unknown marker shape cannot.
Only the exact versioned marker shape is accepted. Heavy package and version
lists are paginated and capped; edge cache keys discard arbitrary query
parameters and retain only the bounded canonical page.
The public compatibility route reads only the Worker's compiled schema contract,
not D1, so rollback preflight remains available when production data is unhealthy.

## Trust boundaries

There are four independent authorities:

1. Registries define accepted provenance and publish source data.
2. GitHub Actions builds candidates and runs checks. Untrusted changes have no
   production credentials.
3. Protected environments hold separate seed-proposal, D1-read, D1-write, and
   Worker-deploy credentials.
4. Cloudflare hosts the immutable Worker revision and mutable D1 dataset.

Repository code cannot attest that hosted rulesets, environment reviewers, or
token scopes are configured correctly. Those controls require periodic
readback as described in [operations.md](operations.md).
