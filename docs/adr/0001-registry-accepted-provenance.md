# ADR 0001: Registry-accepted provenance is the tracked signal

Status: accepted

## Context

RubyGems, crates.io, and PyPI expose different provenance representations.
Rakkan needs a comparable adoption signal without becoming a second registry
or signature-verification service.

## Decision

Record provenance accepted and exposed by the registry. Parse the publisher
identity fields needed for reporting, but do not claim independent signature,
certificate-chain, artifact-digest, or policy verification. Describe RubyGems
attestation presence as a lower bound because an accepted trusted-publisher
push can exist without an attestation.

## Consequences

The signal is public, reproducible, and comparable across registries. It
inherits each registry's verification policy and availability. UI and
documentation must distinguish registry acceptance from independent
cryptographic verification.
