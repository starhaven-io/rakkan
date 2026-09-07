# Contributing

Thank you for improving rakkan. Changes to source, data, workflows, and
documentation are all reviewed as production changes.

## Set up

Use Ruby and Node versions compatible with `.ruby-version` and
`site/package.json`. The complete local gate also requires `just`, ShellCheck,
zizmor, pinprick, and typos-cli. On macOS with Homebrew:

```sh
brew install just shellcheck zizmor pinprick typos-cli
```

Confirm the audit tools, then set up the project:

```sh
just check-tools
bin/setup
just install-hooks
just check
```

`bin/setup` installs dependencies, prepares the engine databases, loads the
committed seed, exports a local D1 database, and installs the site. The test
suite is offline. It does not install machine-wide audit tools. Do not add
tests that call a registry or other live service.

## Make a change

- Create a branch. Never commit directly to `main`.
- Keep registry HTTP access inside `Ingestion::HTTPClient`; do not scrape
  registry HTML.
- Preserve idempotent, resumable ingestion and natural-key upserts.
- Update tests, documentation, and schema contracts with the behavior they
  describe.
- Run `just check` before opening a pull request. It covers the engine and site
  suites with coverage thresholds, formatting, type checking, builds, workflow
  analysis, shell analysis, dependency policy, and spelling.

When changing a tracked seed, use the registry builder and semantic checker.
Never hand-edit a compressed seed. The normal path is a bot-opened seed pull
request from a fixed automation branch.

## Commits and pull requests

Use Conventional Commit titles and sign every commit with DCO:

```sh
git commit -s
```

Pull request descriptions should be concise prose without a standalone test
plan or checklist. If an AI or LLM assisted the pull request, follow the exact
disclosure rule in [AGENTS.md](AGENTS.md). Do not identify an AI system as a
commit author, co-author, committer, or signatory.

Required pull requests, the `conclusion` check, DCO, and Fleet Guard are hosted
repository controls; required approvals are zero while the organization has one
maintainer, so a human merge is the gate. See
[docs/operations.md](docs/operations.md) before changing branch protections,
environments, or production workflows.

## Security reports

Do not disclose a suspected vulnerability in a pull request or issue. Follow
[SECURITY.md](SECURITY.md).
