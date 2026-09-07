# Data freshness and publication invariants

Rakkan favors an explicit stale or failed run over publishing an observation
that cannot be tied to a complete tracked set.

## Cadence and limits

| Signal | Target | Enforced condition |
| --- | --- | --- |
| RubyGems tracked set | Weekly | The committed dump is at most 9 days old when refreshed |
| crates.io tracked set | Weekly from the daily dump | A candidate is at most 2 days old; the committed dump is at most 9 days old when refreshed |
| RubyGems discovery | Each refresh | Every bounded page is validated and the feed must drain before snapshotting |
| Provenance checks | Each refresh | Responses must match the adapter contract; failures do not stamp a check date |
| Adoption snapshot | After complete refresh | The wrapper freezes one UTC date for waiver evaluation and snapshotting; snapshots are withheld while unchecked work or isolated errors remain |
| Public D1 generation | Successful protected refresh | The deployed Worker must accept the candidate schema; schema version and exact table counts must match the local export after replacement |

Candidate freshness uses the dump's own timestamp, with only five minutes of
future clock skew allowed. Source manifests, archive hashes,
rank ordering, identifiers, references, timestamps, booleans, and compressed
semantic content are validated before publication.

Ordinary pull-request CI performs all structural and semantic checks but does
not reject a committed seed merely because time passed. Freshness remains a
publication condition in the protected refresh and updater workflows. An exact
rerun of the current source is a successful no-op; older data and same-timestamp
content changes fail closed.

## Failure behavior

- A missing attestation endpoint or malformed per-version provenance response
  leaves that version unchecked while independent versions continue. The
  refresh still fails and withholds its snapshot after reporting the errors,
  unless an exact non-yanked 404 has a current reviewed waiver. A waiver is
  reported, remains unstamped, and is excluded from the version denominator;
  it never becomes a no-provenance observation. At most 100 exact waivers are
  probed outside the ordinary per-attempt limit, preventing them from starving
  non-waived versions. An expired waiver is ignored with a warning, returning
  its version to the same blocking error path if the registry still omits it.
- Invalid feed JSON, an oversized body, malformed feed entry, non-progressing
  cursor, or partial dump stops the run.
- Registry transport failures are retried within a bounded budget and are not
  converted into negative provenance observations.
- RubyGems discovery and provenance refresh each get at most three resumable
  attempts. The protected all-registry ingestion step has a 70-minute
  wall-clock limit.
- A provenance refresh may persist its checked rows and remaining cursor, but
  it does not create a partial snapshot for either registry.
- A failure before replacement leaves production D1 unchanged. Replacement is
  preceded by a Time Travel bookmark and full SQL evidence export; a failure
  during or after replacement requires remote readback and may require rollback.

## Inspecting freshness

The committed dump time and source are in each registry's
`seed/<registry>/manifest.json`. The public export time and schema version are
in D1's single-row `export_meta` table. Workflow summaries report dump times,
tracked row counts, remaining provenance work, and publication results.

Scheduled seed and refresh workflows maintain one open failure issue per
operation and close it after recovery. A stale manifest, missing scheduled run,
or persistent remaining backlog is actionable even when the public site still
serves the last valid generation.
