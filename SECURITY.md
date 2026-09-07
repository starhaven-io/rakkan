# Security policy

## Supported code

Security fixes target the current `main` branch and the currently deployed
service. Historical commits and locally modified deployments are not supported.

## Reporting a vulnerability

Use a [private GitHub security advisory](https://github.com/starhaven-io/rakkan/security/advisories/new).
Do not open a public issue for a suspected vulnerability. Include the affected
revision or deployment, reproduction steps, impact, and any suggested
mitigation. Please avoid accessing data that is not yours or disrupting the
public service while testing.

The maintainers will acknowledge the report, validate it, coordinate a fix,
and agree on disclosure timing through the private advisory. No fixed response
or remediation deadline is promised.

## Security properties

Changes must preserve these properties:

- Registry traffic goes through `Ingestion::HTTPClient`; adapters use fixed
  HTTPS API origins and escaped request values. Traffic is rate limited and has
  bounded retries and response sizes. Tests never make live network requests.
- Missing, malformed, truncated, stale, or semantically inconsistent registry
  data stops publication. Ingestion remains idempotent and resumable.
- Seed updates are derived from an exact official dump, retain source identity
  and checksums, and pass semantic validation before an automation branch is
  updated.
- Untrusted pull request or push code receives no production credentials.
  Worker deployment, D1 read access, D1 write access, and seed-proposal
  credentials use separate GitHub environments and tokens.
- A site deployment must match the schema version recorded in production D1.
  A data replacement is backed up first and is accepted only after schema and
  exact row-count readback.
- The public adoption signal is registry-accepted provenance. Rakkan does not
  claim to independently verify sigstore or PEP 740 signatures.

The repository can define workflows and checks, but it cannot prove its own
hosted rulesets, environment protections, secret scopes, or Cloudflare token
permissions. The required hosted configuration and verification procedure are
documented in [docs/operations.md](docs/operations.md).
