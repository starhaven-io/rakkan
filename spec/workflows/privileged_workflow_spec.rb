# frozen_string_literal: true

RSpec.describe "privileged workflow security contracts" do
  def workflow(name)
    File.read(Hanami.app.root.join(".github", "workflows", name), encoding: "UTF-8")
  end

  def job(source, name, following_name)
    source.match(/^  #{Regexp.escape(name)}:\n(?<body>.*?)(?=^  #{Regexp.escape(following_name)}:)/m)[:body]
  end

  it "binds Cloudflare jobs to this repository, main, and immutable checkouts" do
    deploy = workflow("deploy-site.yml")
    refresh = job(workflow("refresh-data.yml"), "refresh", "dry-run")

    expect(deploy.scan("github.repository == 'starhaven-io/rakkan'").length).to eq(2)
    expect(deploy.scan("ref: ${{ github.sha }}").length).to eq(2)
    expect(refresh).to include(
      "github.repository == 'starhaven-io/rakkan'",
      "github.ref == 'refs/heads/main'",
      "inputs.authorized_sha == github.sha",
      "ref: ${{ env.AUTHORIZED_SHA }}",
      '[[ "${AUTHORIZED_SHA}" != "${GITHUB_SHA}" ]]'
    )
  end

  it "keeps the push dry run credential-free and separates Cloudflare capabilities" do
    refresh_workflow = workflow("refresh-data.yml")
    refresh = job(refresh_workflow, "refresh", "dry-run")
    dry_run = job(refresh_workflow, "dry-run", "refresh-issue")
    deploy = workflow("deploy-site.yml")

    expect(dry_run).not_to include("environment:", "CLOUDFLARE_", "secrets.")
    expect(refresh).to include("CLOUDFLARE_D1_TOKEN")
    expect(refresh).not_to include("CLOUDFLARE_WORKER_TOKEN", "CLOUDFLARE_D1_READ_TOKEN")
    expect(deploy).to include("CLOUDFLARE_WORKER_TOKEN", "CLOUDFLARE_D1_READ_TOKEN")
    expect(deploy).not_to include("secrets.CLOUDFLARE_D1_TOKEN")
  end

  it "dry-runs every registry when any ingestion input changes" do
    refresh_workflow = workflow("refresh-data.yml")
    dry_run = job(refresh_workflow, "dry-run", "refresh-issue")

    expect(refresh_workflow).to include(
      '- "app/**"',
      '- "config/**"',
      '- "lib/**"',
      '- "research/**"',
      '- "scripts/**"',
      '- "seed/**"',
      '- "slices/ingestion/**"'
    )
    expect(dry_run).to include(
      "REGISTRY=rubygems timeout",
      "REGISTRY=cratesio timeout",
      "bundle exec rake export:d1",
      "verify_d1_export_manifest.rb"
    )
  end

  it "keeps wall-clock freshness out of ordinary CI and aligns npm's cache path" do
    ci = workflow("ci.yml")

    expect(ci).to include(
      "check_rubygems_seed_update.rb --structural seed/rubygems",
      "check_cratesio_seed_update.rb --structural seed/cratesio",
      "NPM_CONFIG_CACHE: ${{ github.workspace }}/var/cache/npm"
    )
    expect(ci).not_to include("check_rubygems_seed_update.rb --current", "check_cratesio_seed_update.rb --current")
  end

  it "captures a Time Travel rollback point and reports rejected refreshes" do
    refresh = workflow("refresh-data.yml")

    expect(refresh).to include(
      "group: d1-production-write",
      "wrangler d1 time-travel info rakkan --json",
      "rakkan-d1-bookmark.txt",
      "needs.refresh.result == 'skipped'",
      "needs.refresh.result == 'cancelled'",
      "Refresh run ${REFRESH_RESULT}"
    )
  end

  it "queues every production transition instead of replacing pending work" do
    %w[deploy-site.yml refresh-data.yml rollback-d1.yml].each do |name|
      source = workflow(name)

      expect(source).to include("d1-production-write", "cancel-in-progress: false", "queue: max")
    end
  end

  it "provides a protected, source-bound Time Travel rollback with readback" do
    rollback = workflow("rollback-d1.yml")

    expect(rollback).to include(
      "github.repository == 'starhaven-io/rakkan'",
      "github.ref == 'refs/heads/main'",
      ".name == \"Refresh Data\"",
      ".path == \".github/workflows/refresh-data.yml\"",
      '.conclusion == "cancelled"',
      '.conclusion == "timed_out"',
      "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c",
      "wrangler d1 time-travel restore rakkan",
      "https://rakkan.dev/health/compatibility/v1.json",
      "index($expected_schema) != null",
      "$expected_schema == $actual_schema",
      "rakkan-d1-recovery.json",
      "verify_d1_recovery_manifest.rb",
      %q(column_names}" != '["generated_at","schema_version"]'),
      "environment: cloudflare-d1",
      "group: d1-production-write"
    )
    expect(rollback).not_to include(
      'sqlite3 "${EXPECTED_DB}" < "${sql_file}"',
      "https://rakkan.dev/health/v1.json",
      %q(column_names}" == '["generated_at"]')
    )
  end

  it "serializes schema transitions and verifies both sides of the compatibility contract" do
    deploy = workflow("deploy-site.yml")
    refresh = workflow("refresh-data.yml")

    expect(deploy).to include(
      "github.ref == 'refs/heads/main' && 'd1-production-write'",
      "format('rejected-deploy-{0}', github.run_id)",
      "cancel-in-progress: false",
      "queue: max",
      ".compatibleVersions",
      "index($actual) != null",
      ".compatibleVersions == $compatible",
      "index($health.schemaVersion)",
      %q(names}" != '["generated_at","schema_version"]'),
      '"${status}" != "200"'
    )
    expect(deploy).not_to include("LEGACY_EXPORT", '"${status}" == "404"', %q(names}" == '["generated_at"]'))
    expect(refresh).to include(
      "Verify deployed Worker accepts candidate schema",
      "https://rakkan.dev/health/v1.json",
      "index($candidate_schema) != null",
      %q(column_names}" != '["generated_at","schema_version"]')
    )
    expect(refresh).not_to include(%q(column_names}" == '["generated_at"]'))
    expect(refresh.index("Verify deployed Worker accepts candidate schema"))
      .to be < refresh.index("Replace production data")
  end

  it "retries the RubyGems updater after a late Monday dump" do
    expect(workflow("update-rubygems-seed.yml")).to include('- cron: "30 03 * * 2"')
  end

  it "binds post-merge seed refreshes to the reviewed merge SHA" do
    %w[
      refresh-cratesio-after-seed-merge.yml
      refresh-rubygems-after-seed-merge.yml
    ].each do |name|
      listener = workflow(name)
      expect(listener).to include(
        "github.repository == 'starhaven-io/rakkan'",
        "MERGE_SHA: ${{ github.event.pull_request.merge_commit_sha }}",
        'main_sha="$(gh api "repos/${REPOSITORY}/git/ref/heads/main" --jq \'.object.sha\')"',
        "compare/${MERGE_SHA}...${main_sha}",
        "($files | length) >= 1",
        '--field authorized_sha="${main_sha}"',
        '--field request_id="${request_id}"',
        "--field registry=all",
        'timeout 150m gh run watch "${refresh_run_id}"',
        "--json status,conclusion,jobs",
        '"${status}" != "completed"'
      )
      expect(listener).not_to include('.status == "in_progress" or .status == "queued"')
    end
  end

  it "leaves byte-identical open seed proposals untouched" do
    %w[update-cratesio-seed.yml update-rubygems-seed.yml].each do |name|
      updater = workflow(name)
      expect(updater).to include(
        "pull-requests: read",
        "scripts/seed-proposal-needed.sh",
        "update_required: ${{ steps.proposal.outputs.update_required }}",
        "if: steps.proposal.outputs.update_required == 'true'"
      )
    end
  end

  it "publishes a checksum-bound recovery manifest before replacement" do
    refresh = workflow("refresh-data.yml")

    expect(refresh).to include(
      "rakkan-d1-recovery.json",
      "backup_sha256",
      "schema_version",
      "generated_at",
      "verify_d1_recovery_manifest.rb"
    )
    expect(refresh.index("rakkan-d1-recovery.json")).to be < refresh.index("Replace production data")
  end

  it "accepts production replacement only when the candidate identity and counts are readable" do
    refresh = workflow("refresh-data.yml")

    expect(refresh).to include(
      "verify_d1_export_manifest.rb",
      "db/d1_export.meta.json db/d1_export.sql",
      'previous_generated_at="$(jq -er \'.generated_at\' "${D1_RECOVERY_MANIFEST}")"',
      '[[ "${candidate_generated_at}" == "${previous_generated_at}" ]]',
      "id: replace",
      "--remote --file=../db/d1_export.sql --yes || import_exit_code=$?",
      "IMPORT_EXIT_CODE: ${{ steps.replace.outputs.exit_code }}",
      '[[ ! "${IMPORT_EXIT_CODE}" =~ ^[0-9]+$ ]]',
      "if (( IMPORT_EXIT_CODE != 0 )); then",
      "max_attempts=120",
      ".generated_at == $expected.generated_at",
      "D1 export artifacts changed or became invalid after replacement",
      "could not read a valid production D1 state after replacement",
      "production D1 generation or table counts do not match the exported candidate",
      'if [[ -n "${last_result}" ]]; then',
      "Last observed production state:",
      "production matches the candidate generation and table counts",
      "GITHUB_STEP_SUMMARY"
    )
    expect(refresh).to match(
      /if \[\[ "\$\{verified\}" != true \]\]; then\n.*?exit 1\n\s+fi/m
    )
    expect(refresh.index("verify_d1_export_manifest.rb")).to be < refresh.index("id: replace")
    expect(refresh.index("id: replace")).to be < refresh.index("Verify replacement")
    expect(refresh).not_to include("--file=../db/d1_export.sql --yes > /dev/null")
  end
end
