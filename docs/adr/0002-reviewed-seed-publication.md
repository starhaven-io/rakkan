# ADR 0002: Publish tracked sets through reviewed seed pull requests

Status: accepted

## Context

Tracked-set changes alter the denominator and can move adoption metrics without
any package changing its publishing behavior. Dump parsers and automation also
process large, externally controlled inputs.

## Decision

Build seed candidates in credential-free jobs, validate source freshness and
semantic invariants, and transfer only the exact candidate artifact to a
credentialed proposal job. That job may update a fixed automation branch and
open a pull request, but it cannot approve or merge. A post-merge listener
dispatches production refresh only for the expected branch and seed-only file
set.

## Consequences

Tracked-set drift is visible and reviewable, and untrusted input is separated
from proposal credentials. Production still depends on hosted rulesets to
require a human approval; that control must be verified outside the repository.
