# ADR 0003: Replace D1 from one versioned SQLite export

Status: accepted

## Context

The engine and Worker must agree on schema and observe one internally
consistent data generation. Incremental remote writes would expose partial
refreshes and complicate recovery.

## Decision

Generate schema and data from one SQLite read transaction, include an explicit
schema version and generation timestamp, capture a Time Travel bookmark, then
execute the complete export against D1. Emit the `export_meta` acceptance marker
after all data statements. Accept the replacement only after remote schema and
exact row-count readback. Block Worker deployment and runtime rendering when
the database version is outside the Worker's explicit compatibility set. Bind
each recovery bookmark to a small manifest containing its schema, generation,
exact counts, and the evidence export's checksum.

## Consequences

Cloudflare's
[D1 import process](https://developers.cloudflare.com/d1/best-practices/import-export-data/)
makes the database unavailable during import and rolls a failed import back,
so replacement can cause temporary unavailability. Marker-last ordering
also prevents the application from accepting an incomplete generation if
those platform semantics change. Rollback uses the captured Time Travel
bookmark and manifest; the SQL export is secondary evidence, not a portability
gate or directly replayable populated-database restore. A temporarily missing
marker may fall back to a warm Worker's last accepted cache generation, but a
version mismatch remains fatal. The replacement is a privileged operation and
must remain isolated in the protected D1 environment. Schema-dependent Worker
changes require a deliberate compatibility-bridge rollout.
