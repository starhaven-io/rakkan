# Setup

# Install engine dependencies
install:
    bundle install

# Install site dependencies under the reviewed install-script policy
install-site:
    node scripts/check-npm-install-policy.mjs site
    cd site && npm ci --strict-allow-scripts

# Create and migrate the development and test databases
db-prepare:
    HANAMI_LOG_LEVEL=info bundle exec hanami db prepare

# Data

# Load a registry's tracked set from committed seed data (no network; idempotent)
seed registry="rubygems":
    HANAMI_LOG_LEVEL=info bundle exec rake "ingest:seed[{{ registry }}]"

# Discover versions published since a registry's seed dump (live API)
discover registry="rubygems":
    HANAMI_LOG_LEVEL=info bundle exec rake "ingest:discover[{{ registry }}]"

# Check up to N ordinary versions plus bounded exact waiver probes (live API)
refresh n="50" registry="rubygems":
    HANAMI_LOG_LEVEL=info bundle exec rake "ingest:refresh[{{ n }},{{ registry }}]"

# Record the current adoption snapshot for a registry
snapshot registry="rubygems":
    HANAMI_LOG_LEVEL=info bundle exec rake "snapshot:take[{{ registry }}]"

# Export the database for the Workers site's D1 (db/d1_export.sql)
export-d1:
    HANAMI_LOG_LEVEL=info bundle exec rake export:d1

# Load the export into the site's local D1 (requires `just install-site`)
site-db: export-d1
    cd site && WRANGLER_WRITE_LOGS=false ./node_modules/.bin/wrangler d1 execute rakkan --local --file=../db/d1_export.sql > /dev/null

# Run

# Start the site dev server (Astro on a local D1) on http://localhost:4321
dev:
    cd site && npm run dev

# Open the engine console
console:
    bundle exec hanami console

# Test

# Run the spec suite (no network)
test:
    bundle exec rspec

# Validate committed tracked sets structurally; protected refreshes enforce freshness
check-seeds:
    bundle exec ruby research/check_rubygems_seed_update.rb --structural seed/rubygems
    bundle exec ruby research/check_cratesio_seed_update.rb --structural seed/cratesio

# Check external executables required by the complete local gate
check-tools:
    bash scripts/check-tools.sh

# Run all test suites and write the Codecov coverage reports
test-cov:
    COVERAGE=true bundle exec rspec
    cd site && npm run test:coverage

# Lint

# Lint Ruby style
rubocop:
    bundle exec rubocop --cache-root var/cache/rubocop

# Format site files with Prettier
site-format:
    cd site && npm run format

# Check site formatting
site-format-check:
    cd site && npm run format:check

# Type-check the Astro site
site-check:
    cd site && npm run check

# Check

# Run all checks
check:
    #!/usr/bin/env bash
    set -euo pipefail
    failed=0
    skipped=()
    run() {
        echo "--- $1 ---"
        shift
        if ! "$@"; then
            failed=1
        fi
    }
    skip() {
        echo "--- $1 --- skipped ($2 not found)"
        skipped+=("$2 (brew install $3)")
    }
    run_tool() {
        local name="$1" tool="$2" package="$3"
        shift 3
        if command -v "$tool" >/dev/null 2>&1; then
            run "$name" "$@"
        else
            skip "$name" "$tool" "$package"
        fi
    }
    run tools just check-tools
    run npm-policy node scripts/check-npm-install-policy.mjs site
    run seeds just check-seeds
    run rspec env COVERAGE=true bundle exec rspec
    run rubocop bundle exec rubocop --cache-root var/cache/rubocop
    run_tool shellcheck shellcheck shellcheck shellcheck bin/setup scripts/*.sh
    run_tool zizmor zizmor zizmor zizmor --strict-collection --persona auditor .github/workflows/
    run_tool pinprick pinprick pinprick pinprick audit .
    if [ -d site/node_modules ]; then
        run site-format bash -c 'cd site && npm run --silent format:check'
        run site-check bash -c 'cd site && npm run --silent check'
        run site-tests bash -c 'cd site && npm run --silent test:coverage'
        run site-build bash -c 'cd site && ./node_modules/.bin/astro build --silent > /dev/null'
    else
        skip site-tests node_modules "just install-site"
    fi
    run_tool typos typos typos-cli typos
    if [ ${#skipped[@]} -gt 0 ]; then
        echo ""
        echo "Checks skipped due to missing tools:"
        for tool in "${skipped[@]}"; do
            echo "  - $tool"
        done
        failed=1
    fi
    exit $failed

# Check documentation links
lychee:
    lychee --config lychee.toml README.md AGENTS.md CLAUDE.md DATA_SOURCES.md SECURITY.md CONTRIBUTING.md CODE_OF_CONDUCT.md seed/README.md docs/architecture.md docs/data-freshness.md docs/operations.md

# fleet:block install-hooks
# Install git hooks (AI trailer guard + DCO sign-off + pre-push checks). Run once per clone.
install-hooks:
    git config core.hooksPath .githooks
# fleet:end

# fleet:block npm-policy
# Verify every dependency install script is denied or exactly approved
npm-policy:
    node scripts/check-npm-install-policy.mjs site
# fleet:end

# fleet:block audit
audit:
    zizmor --strict-collection --persona auditor .github/workflows/
# fleet:end

# fleet:block pinprick-audit
pinprick-audit:
    pinprick audit .
# fleet:end
