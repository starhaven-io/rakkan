# frozen_string_literal: true

require "fileutils"
require "open3"
require "shellwords"
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

  it "isolates the dry run from inherited Ruby shims, preload hooks, and database settings" do
    Dir.mktmpdir("rakkan-ambient-ruby") do |directory|
      marker = File.join(directory, "escaped")
      write_executable(directory, "ruby", <<~BASH)
        #!/bin/bash
        printf 'ruby shim ran' > #{Shellwords.escape(marker)}
        exit 64
      BASH
      preload = File.join(directory, "preload.rb")
      File.write(preload, "File.write(#{marker.inspect}, 'preload ran'); exit 65\n")
      [
        { "PATH" => directory },
        { "RUBYOPT" => "-r#{preload}", "BUNDLER_SETUP" => preload }
      ].each do |ambient|
        original_env = ENV.to_h
        begin
          ENV.update(ambient.merge("HANAMI_ENV" => "development", "DATABASE_URL" => "sqlite://#{marker}"))
          run_step do |result|
            expect(result.fetch(:status)).to be_success, result.fetch(:stderr)
            expect(result.fetch(:calls)).to include("exec rake ingest:seed[rubygems]")
          end
          expect(File).not_to exist(marker)
        ensure
          ENV.replace(original_env)
        end
      end
    end
  end

  def run_step
    Dir.mktmpdir("rakkan-dry-run") do |directory|
      bin = File.join(directory, "bin")
      FileUtils.mkdir_p([bin, File.join(directory, "scripts")])
      FileUtils.cp(Hanami.app.root.join("scripts", "refresh-registry-data.rb"), File.join(directory, "scripts"))
      calls = File.join(directory, "calls")
      File.write(calls, "")
      write_executable(bin, "ruby", <<~BASH)
        #!/bin/bash
        exec #{Shellwords.escape(File.realpath(RbConfig.ruby))} "$@"
      BASH
      write_executable(bin, "bundle", <<~'BASH')
        #!/bin/bash
        [[ -z "${DATABASE_URL:-}${RUBYOPT:-}${BUNDLER_SETUP:-}" ]] || exit 66
        printf '%s\n' "$*" >> "${CALLS}"
        case "$*" in
          *"ingest:refresh"*rubygems*) printf '{"remaining":0,"errors":0,"waived":0}\n' ;;
          *"ingest:refresh"*cratesio*) printf '{"remaining":4000,"errors":0,"waived":0}\n' ;;
        esac
      BASH
      write_executable(bin, "timeout", <<~BASH)
        #!/bin/bash
        while [[ "$1" == --* ]]; do shift; done
        shift
        exec "$@"
      BASH
      env = {
        "CALLS" => calls,
        "GITHUB_STEP_SUMMARY" => File.join(directory, "summary"),
        "PATH" => "#{bin}:/usr/bin:/bin",
        "HANAMI_ENV" => "test",
        "PIPELINE_DATE" => "2026-09-22"
      }
      # A missing stub must fail outside the application, never reach a real database or registry.
      _stdout, stderr, status = Open3.capture3(
        env, "/bin/bash", "-euo", "pipefail", "-c", step.fetch("run"), chdir: directory, unsetenv_others: true
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
