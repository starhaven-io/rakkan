# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

RSpec.describe "Refresh Data push dry run" do
  let(:step) do
    workflow = YAML.safe_load_file(Hanami.app.root.join(".github", "workflows", "refresh-data.yml"))
    workflow.fetch("jobs").fetch("dry-run").fetch("steps")
            .find { |candidate| candidate["name"] == "Exercise ingestion and export without production credentials" }
  end

  it "completes RubyGems but caps crates.io's fresh backfill before exporting" do
    run_step do |result|
      expect(result.fetch(:status)).to be_success, result.fetch(:stderr)
      calls = result.fetch(:calls)
      expect(calls.grep(/ingest:refresh\[/)).to eq(
        ["exec rake ingest:refresh[250,rubygems,2026-09-22]"] +
        (["exec rake ingest:refresh[5,cratesio,2026-09-22]"] * 3)
      )
      expect(calls).to include("exec rake snapshot:take[rubygems,2026-09-22]")
      expect(calls).not_to include(match(/snapshot:take\[cratesio/))
      expect(calls.last(2)).to eq(
        [
          "exec rake export:d1",
          "exec ruby scripts/verify_d1_export_manifest.rb db/d1_export.meta.json db/d1_export.sql"
        ]
      )
    end
  end

  def run_step
    Dir.mktmpdir("rakkan-dry-run") do |directory|
      calls = File.join(directory, "calls")
      File.write(calls, "")
      write_executable(directory, "bundle", <<~'BASH')
        #!/usr/bin/env bash
        printf '%s\n' "$*" >> "${CALLS}"
        case "$*" in
          *"ingest:refresh"*rubygems*) printf '{"remaining":0,"errors":0,"waived":0}\n' ;;
          *"ingest:refresh"*cratesio*) printf '{"remaining":4000,"errors":0,"waived":0}\n' ;;
        esac
      BASH
      write_executable(directory, "timeout", <<~BASH)
        #!/usr/bin/env bash
        while [[ "$1" == --* ]]; do shift; done
        shift
        exec "$@"
      BASH
      env = {
        "CALLS" => calls,
        "GITHUB_STEP_SUMMARY" => File.join(directory, "summary"),
        "PATH" => "#{directory}:#{ENV.fetch("PATH")}",
        "PIPELINE_DATE" => "2026-09-22"
      }
      _stdout, stderr, status = Open3.capture3(
        env, "bash", "-euo", "pipefail", "-c", step.fetch("run"), chdir: Hanami.app.root.to_s
      )
      yield(status:, stderr:, calls: File.readlines(calls, chomp: true))
    end
  end

  def write_executable(directory, name, source)
    path = File.join(directory, name)
    File.write(path, source)
    FileUtils.chmod(0o755, path)
  end
end
