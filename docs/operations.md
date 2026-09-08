# Operations runbook

This runbook covers hosted configuration, scheduled data publication, site
deployment, rollback, and incident handling. Local checks cannot verify these
hosted controls.

## Required hosted controls

Protect `main` with a GitHub ruleset that:

- requires pull requests, with squash as the only merge method;
- requires the `conclusion` status from `.github/workflows/ci.yml`, plus the
  organization's DCO and Fleet Guard workflow rules;
- prevents force pushes and branch deletion;
- gives automation no review or ruleset-bypass authority, except for a
  separately audited emergency path.

Required approvals are deliberately zero while the organization has a single
maintainer. GitHub does not permit self-approval and the ruleset carries no
bypass actors, so requiring one approval would make every maintainer-authored
pull request permanently unmergeable. The enforced gate on a bot-opened seed
pull request is therefore a human merge rather than a human approval; the
proposal workflows never call the merge API, and their app token is minted per
run. When another trusted maintainer can provide independent review, reassess
required approvals and stale-review dismissal, then update this policy and its
provider configuration together.

Configure these GitHub environments and keep their credentials disjoint:

| Environment | Repository values | Purpose |
| --- | --- | --- |
| `starhaven` | `APP_CLIENT_ID`, `APP_PRIVATE_KEY` | Update a fixed seed automation branch and open a pull request |
| `cloudflare-d1-read` | `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_D1_READ_TOKEN` | Read only the production schema contract before site deploy |
| `cloudflare-d1` | `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_D1_TOKEN` | Export, replace, restore, and verify production D1 |
| `cloudflare-worker` | `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_WORKER_TOKEN` | Deploy the Worker without D1-write or zone-route authority |

Restrict production environments to the `main` branch, excluding tags named
`main`. While there is one maintainer, do not require a second reviewer or
self-approval; the reviewed pull request, explicit recovery dispatch, and
scoped credentials provide the operational gates. Reassess independent review
when another trusted maintainer can provide it. Set the shortest practical
token lifetime and scope. The custom domain is managed out of band; the Worker
token must not receive zone route permissions.

After any workflow, ruleset, environment, app, or token change, read the hosted
configuration back through the provider APIs and confirm the effective state.
Repeat that audit periodically. A green local or hosted workflow does not prove
that bypass actors or token scopes are correct.

## Seed publication

The Monday RubyGems and crates.io update workflows fetch official dumps into
runner-temporary storage, build a deterministic candidate, and apply semantic
and freshness checks. RubyGems retries early Tuesday in case its Monday dump is
late; receiving the exact already-committed dump is a successful no-op. When
content changes, a GitHub App updates only the
registry's fixed `automation/*-seed` branch and opens or refreshes a pull
request. Before packaging or mutating anything, the unprivileged job compares
the candidate bytes with the exact expected files on the single open
same-repository automation pull request. Fork pull requests with the same branch
name are ignored. The pull-request diff must be a nonempty allowed subset that
includes `manifest.json`; every candidate file is still compared against the
full head tree. An identical proposal is left untouched so a scheduled retry
does not reset its head or dismiss a valid approval. Multiple same-repository
proposals, extra files, a truncated tree response, or an unreadable blob fails
closed.

Review the manifest source and timestamp, semantic row-count summary, and exact
file list. Merge only after required CI passes and you have read the diff. The
post-merge listener accepts only the expected repository, `main` base, fixed
automation branch, seed-only file set, and exact merge SHA. It requires that
merge to remain an ancestor of current `main`, authorizes one immutable current
SHA, and watches the protected refresh until completion or its bounded wait
expires. A cancelled or skipped dispatch is retried. Each listener requests an
all-registry refresh. The shared production concurrency group retains up to 100
pending deploys, refreshes, and rollbacks, preventing two listeners from
replacing each other's child runs. The listener waits for a bounded period; if
the child is still queued, pending, requested, or waiting for environment
approval, that protected child remains authoritative and reports its own
eventual result.

## Protected data refresh

`Refresh Data` is the sole routine production D1 publisher; `Roll back D1` is
the manually dispatched recovery writer. Refresh Data checks out and verifies
the exact triggering `main` SHA, restores current production history into a
fresh engine database, validates and ingests the committed seed, drains or
advances registry work, creates a snapshot only when complete, and exports a
new D1 image.

Before replacement it captures a pre-refresh
[D1 Time Travel](https://developers.cloudflare.com/d1/reference/time-travel/)
bookmark and
uploads it with a small recovery manifest containing the bookmark, schema,
generation, exact table counts, and the full SQL export's SHA-256. The SQL is
retained for audit and offline recovery work; its ability to replay in local
SQLite is not a precondition for Time Travel rollback. After
replacement it compares the remote schema version and exact row counts with the
local export. Immediately before replacement it also requires the deployed
Worker's uncached health response to advertise support for the candidate schema.
Worker deployment, refresh replacement, and rollback are serialized under one
production schema-transition lock. Push-triggered dry runs use a fresh local
database and have no Cloudflare environment or token.

Persistent registry 404s are not silently converted to no-provenance results.
First confirm that the exact version is non-yanked and permanently absent, then
add its registry, package, version, platform, reason, and a short expiry to
`config/provenance_not_found_waivers.json`. Wildcards, duplicate identities,
more than 100 entries, invalid dates, and malformed documents stop ingestion.
An expired entry emits a warning and becomes inactive; it cannot waive a 404 or
alter snapshot counts, and it does not stop unrelated registry work. The
exact waiver candidates are probed outside the ordinary per-attempt limit so
they cannot starve normal provenance work. The exception applies only when that
exact request returns 404, leaves the row unchecked, and excludes the unresolved
version from snapshot version counts. Malformed successful
responses and transport failures still block publication. If a stale positive
claim is rechecked and receives the waived 404, the claim is cleared while the
row returns to unchecked state. Remove the waiver as soon as the registry
exposes the version or the tracked set no longer needs it.
The refresh wrapper captures one UTC run date and passes it to every refresh
attempt and the final snapshot. A waiver cannot change status between those
subprocesses if the run crosses midnight.

## Schema changes

`site/schema-contract.json` declares both the schema written by the engine and
the versions the Worker can read. For an incompatible N to N+1 change, land and
run changes in this order:

1. Deploy a bridge Worker whose compatibility set contains N and N+1 while its
   queries still work with both schemas.
2. Merge the engine migration and export version N+1, keeping N and N+1 in the
   compatibility set, then dispatch `Refresh Data` and verify readback.
3. Deploy the Worker query that requires N+1.
4. After the rollback window, remove N from the compatibility set.

`Deploy Site` holds the production transition lock across its read-only remote
contract check and Worker deployment, then rechecks the public health response.
A version outside the declared compatibility set fails deployment. The deployed
health response exposes both its current database version and the Worker's
compatibility set; `Refresh Data` checks that set before replacement. The
runtime also fails closed if an incompatible database reaches it.

Every pre-deploy and post-deploy health check requires HTTP 200.

Only the exact versioned `export_meta` marker shape is accepted. Unknown marker
shapes fail closed. During replacement, a temporarily absent marker may use a
warm isolate's last accepted cache generation, while a schema mismatch is always
fatal.

## Rollback

For a bad data replacement:

1. Stop further refresh dispatches and preserve the failed run URL and logs.
   Inspect the production concurrency queue and cancel obsolete pending work so
   an emergency rollback is not delayed behind routine transitions.
2. Download the `rakkan-d1-backup-<run-id>` artifact from the immediately
   preceding refresh and verify it contains the expected Time Travel bookmark,
   recovery manifest, and checksum-matching SQL evidence export.
3. From `main`, dispatch `Roll back D1` with the source Refresh Data run ID.
   Check the terminal run and artifact before dispatch; the main-only
   `cloudflare-d1` environment supplies the scoped recovery credential. A successful, failed, cancelled, or timed-out
   source run is eligible only when the expected recovery artifact exists and
   passes all validation. The workflow validates the bounded manifest and
   evidence checksum, uses the Worker's D1-independent compatibility route to
   require support for the rollback schema, restores the bookmark, and compares
   remote generation, schema, and row counts. It does not gate Time Travel on
   replaying Wrangler's evidence SQL through a different SQLite runtime.
4. Query `export_meta` and all four table counts, then load the public overview
   and representative package routes.
5. Record the incident and repair the source pipeline before re-enabling the
   schedule.

For a bad Worker deployment, redeploy a known-good `main` revision only after
its schema compatibility set is confirmed against production D1. Do not fix a
Worker/data mismatch by bypassing the schema preflight.

Workflow artifacts are retained for seven days, and Time Travel is bounded by
the Cloudflare account's retention window. The raw SQL export is not directly
replayable into a populated D1 database; retain it as evidence and for a tested
empty-database recovery procedure. Local replay is advisory and must not
replace the manifest checksum and post-restore remote readback. If a longer
recovery window is required,
copy the artifact to the organization's approved durable backup system without
placing credentials or private incident data in the repository.

## Incident triage

- Treat unexpected zero counts, a schema mismatch, a stale manifest, a feed
  contract error, or a seed file-set violation as a publication stop.
- Determine whether production changed. A failure before the D1 execute step
  leaves production untouched; a failure during or after it requires remote
  readback and may require rollback.
- Rotate a token if logs or artifacts could have exposed it. Never paste secret
  values into an issue.
- Preserve manifests, checksums, workflow run identifiers, and the exact
  deployed commit as evidence.
- Close the automated failure issue only after successful readback, not merely
  after a rerun starts.
