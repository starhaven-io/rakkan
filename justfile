# Setup

# Install dependencies
install:
    bundle install

# Create and migrate the development and test databases
db-prepare:
    bundle exec hanami db prepare

# Data

# Load the tracked set from committed seed data (no network; idempotent)
seed:
    bundle exec rake ingest:seed

# Discover versions published since the seed dump (live API)
discover:
    bundle exec rake ingest:discover

# Check provenance for up to N unchecked versions (live API)
refresh n="50":
    bundle exec rake "ingest:refresh[{{ n }}]"

# Record today's adoption snapshot
snapshot:
    bundle exec rake snapshot:take

# Export the database for the Workers site's D1 (db/d1_export.sql)
export-d1:
    bundle exec rake export:d1

# Load the export into the site's local D1 (requires site deps: cd site && npm ci)
site-db: export-d1
    cd site && ./node_modules/.bin/wrangler d1 execute rakkan --local --file=../db/d1_export.sql

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

# Lint

# Lint Ruby style
rubocop:
    bundle exec rubocop

# Check

# Run all checks
check:
    #!/usr/bin/env bash
    set -euo pipefail
    failed=0
    skipped=()
    run() {
        echo "--- $1 ---"
        if ! "$@"; then
            failed=1
        fi
    }
    skip() {
        echo "--- $1 --- skipped ($2 not found)"
        skipped+=("$2 (brew install $3)")
    }
    run bundle exec rspec
    run bundle exec rubocop
    if [ -d site/node_modules ]; then
        run bash -c 'cd site && npm run --silent test'
        run bash -c 'cd site && ./node_modules/.bin/astro build --silent > /dev/null'
    else
        skip site-tests node_modules "just install-site (cd site && npm ci)"
    fi
    if command -v typos &>/dev/null; then
        run typos
    else
        skip typos typos typos-cli
    fi
    if [ ${#skipped[@]} -gt 0 ]; then
        echo ""
        echo "Checks skipped due to missing tools:"
        for tool in "${skipped[@]}"; do
            echo "  - $tool"
        done
        failed=1
    fi
    exit $failed

# fleet:block install-hooks
# fleet:end

# fleet:block npm-policy
# fleet:end

# fleet:block audit
# fleet:end

# fleet:block pinprick-audit
# fleet:end
