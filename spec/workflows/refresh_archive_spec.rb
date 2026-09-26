# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"
require "zlib"

RSpec.describe "Refresh Data export archive" do
  let(:steps) do
    workflow = YAML.safe_load_file(Hanami.app.root.join(".github", "workflows", "refresh-data.yml"))
    workflow.fetch("jobs").fetch("refresh").fetch("steps")
  end
  let(:step) { steps.find { |candidate| candidate["name"] == "Archive candidate export" } }
  let(:generated_at) { "2026-09-22 11:50:16.177836" }
  let(:prefix) { "generations/2026-09-22T11-50-16.177836Z" }

  it "archives every generation before it can replace production" do
    names = steps.map { |candidate| candidate["name"] }

    expect(names.index("Archive candidate export")).to be < names.index("Replace production data")
    expect(step.fetch("env")).to include(
      "AWS_ACCESS_KEY_ID" => "${{ secrets.R2_ARCHIVE_ACCESS_KEY_ID }}",
      "AWS_SECRET_ACCESS_KEY" => "${{ secrets.R2_ARCHIVE_SECRET_ACCESS_KEY }}"
    )
    other_steps = steps.reject { |candidate| candidate.equal?(step) }
    expect(other_steps.to_s).not_to include("R2_ARCHIVE")
  end

  it "uploads the export pair under its generation and verifies the readback" do
    run_step do |result|
      expect(result.fetch(:status)).to be_success, result.fetch(:stderr)
      archived = File.join(result.fetch(:bucket), prefix)
      expect(Zlib::GzipReader.open(File.join(archived, "d1_export.sql.gz"), &:read)).to eq(sql)
      expect(File.read(File.join(archived, "d1_export.meta.json"))).to eq(metadata)
      expect(result.fetch(:summary)).to include("rakkan-d1-archive/#{prefix}/")
    end
  end

  it "fails before replacement when an archived object does not read back identically" do
    run_step(overrides: { "FAKE_R2_CORRUPT_READBACK" => "1" }) do |result|
      expect(result.fetch(:status)).not_to be_success
      expect(result.fetch(:stdout)).to include("archived d1_export.sql.gz does not read back identically")
    end
  end

  it "refuses a noncanonical generation before uploading anything" do
    run_step(generated_at: "2026-09-22 11:50:16") do |result|
      expect(result.fetch(:status)).not_to be_success
      expect(Dir.children(result.fetch(:bucket))).to be_empty
    end
  end

  def sql = "CREATE TABLE export_meta (generated_at timestamp NOT NULL);\n"

  def metadata(value = generated_at) = "#{JSON.pretty_generate(generated_at: value, schema_version: 1)}\n"

  def run_step(overrides: {}, generated_at: self.generated_at)
    Dir.mktmpdir("rakkan-archive") do |directory|
      workspace = File.join(directory, "workspace")
      bucket = File.join(directory, "bucket")
      bin = File.join(directory, "bin")
      runner_temp = File.join(directory, "runner-temp")
      [File.join(workspace, "db"), bucket, bin, runner_temp].each { |path| FileUtils.mkdir_p(path) }
      File.write(File.join(workspace, "db", "d1_export.sql"), sql)
      File.write(File.join(workspace, "db", "d1_export.meta.json"), metadata(generated_at))
      File.write(File.join(bin, "aws"), fake_aws)
      FileUtils.chmod(0o755, File.join(bin, "aws"))
      summary = File.join(directory, "summary")
      File.write(summary, "")

      env = step.fetch("env").transform_values { |value| value.gsub(/\$\{\{[^}]*\}\}/, "stub") }.merge(
        "FAKE_R2_ROOT" => bucket,
        "GITHUB_STEP_SUMMARY" => summary,
        "PATH" => "#{bin}:#{ENV.fetch("PATH")}",
        "RUNNER_TEMP" => runner_temp
      ).merge(overrides)
      stdout, stderr, status = Open3.capture3(
        env, "bash", "-euo", "pipefail", "-c", step.fetch("run"), chdir: workspace
      )
      yield(status:, stdout:, stderr:, bucket:, summary: File.read(summary))
    end
  end

  def fake_aws
    <<~BASH
      #!/usr/bin/env bash
      set -euo pipefail
      operation="$2"
      shift 2
      positional=()
      while (( $# > 0 )); do
        case "$1" in
          --key) key="$2"; shift 2 ;;
          --body) body="$2"; shift 2 ;;
          --*) shift 2 ;;
          *) positional+=("$1"); shift ;;
        esac
      done
      object="${FAKE_R2_ROOT}/${key}"
      case "${operation}" in
        put-object)
          mkdir -p "$(dirname "${object}")"
          cp "${body}" "${object}"
          ;;
        get-object)
          cp "${object}" "${positional[0]}"
          if [[ -n "${FAKE_R2_CORRUPT_READBACK:-}" ]]; then printf 'x' >> "${positional[0]}"; fi
          ;;
      esac
    BASH
  end
end
