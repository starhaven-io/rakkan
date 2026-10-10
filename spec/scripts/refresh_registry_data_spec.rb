# frozen_string_literal: true

require "open3"
require "tmpdir"

RSpec.describe "refresh-registry-data.rb" do
  let(:script) { Hanami.app.root.join("scripts", "refresh-registry-data.rb").to_s }

  it "continues bounded successful batches until provenance is complete, then snapshots" do
    run_refresh("REFRESH_1" => "2", "REFRESH_2" => "1", "REFRESH_3" => "0") do |result|
      expect(result.fetch(:status)).to be_success
      expect(result.fetch(:calls).grep(/ingest:refresh/).length).to eq(3)
      expect(result.fetch(:calls)).to include(match(/snapshot:take\[rubygems,2026-09-07\]/))
      expect(result.fetch(:calls).grep(/ingest:refresh|snapshot:take/))
        .to all(include("2026-09-07"))
      expect(result.fetch(:summary)).to include("rubygems: 0 tracked versions remain unchecked")
      expect(result.fetch(:summary)).to include("0 exact provenance 404 waivers")
    end
  end

  it "publishes resumable progress without a partial snapshot after the batch budget" do
    run_refresh("REGISTRY" => "cratesio", "REFRESH_1" => "2", "REFRESH_2" => "1", "REFRESH_3" => "1") do |result|
      expect(result.fetch(:status)).to be_success
      expect(result.fetch(:calls)).not_to include(match(/ingest:discover/))
      expect(result.fetch(:calls)).not_to include(match(/snapshot:take/))
      expect(result.fetch(:summary)).to include("cratesio refresh remains in progress")
    end
  end

  it "parses the final counts after UTF-8 progress messages without a locale" do
    run_refresh("REFRESH_MESSAGE" => "🌸 café") do |result|
      expect(result.fetch(:status)).to be_success, result.fetch(:stderr)
      expect(result.fetch(:stdout).b).to include("🌸 café".b)
      expect(result.fetch(:calls)).to include(match(/snapshot:take/))
    end
  end

  it "fails closed when a refresh omits its authoritative remaining count" do
    run_refresh("REFRESH_1" => "not-json") do |result|
      expect(result.fetch(:status)).not_to be_success
      expect(result.fetch(:stderr)).to include("did not report a valid remaining count")
      expect(result.fetch(:calls)).not_to include(match(/snapshot:take/))
    end
  end

  it "reports an invalid remaining count for empty output without an internal exception" do
    ["", "\n", "\n\n"].each do |output|
      run_refresh("REFRESH_OUTPUT" => output) do |result|
        expect(result.fetch(:status).exitstatus).to eq(1)
        expect(result.fetch(:stderr)).to eq("ingest:refresh did not report a valid remaining count\n")
        expect(result.fetch(:calls).grep(/ingest:refresh/).length).to eq(1)
        expect(result.fetch(:calls)).not_to include(match(/snapshot:take/))
        expect(result.fetch(:summary)).to be_empty
      end
    end
  end

  it "rejects a whitespace-only final line instead of accepting an earlier JSON report" do
    payload = JSON.generate(remaining: 0, errors: 0, waived: 0)
    ["\n \t\n", "\n \t", "\n\r\n", "\n\n \t\n\n"].each do |suffix|
      run_refresh("REFRESH_OUTPUT" => "#{payload}#{suffix}") do |result|
        expect(result.fetch(:status).exitstatus).to eq(1)
        expect(result.fetch(:stderr)).to eq("ingest:refresh did not report a valid remaining count\n")
        expect(result.fetch(:calls)).not_to include(match(/snapshot:take/))
        expect(result.fetch(:summary)).to be_empty
      end
    end
  end

  it "accepts UTF-8 JSON with trailing newlines or whitespace on the JSON line without a locale" do
    payload = JSON.generate(remaining: 0, errors: 0, waived: 0, message: "🌸 café")
    ["", "\n", "\n\n", " \t\n\n", "\r\n"].each do |suffix|
      run_refresh("REFRESH_OUTPUT" => "#{payload}#{suffix}") do |result|
        expect(result.fetch(:status)).to be_success, result.fetch(:stderr)
        expect(result.fetch(:stdout).b).to include("🌸 café".b)
        expect(result.fetch(:calls)).to include(match(/snapshot:take/))
      end
    end
  end

  it "persists independent progress but fails and withholds a snapshot when version errors remain" do
    run_refresh("REFRESH_1" => "2", "REFRESH_2" => "1", "REFRESH_3" => "1",
                "ERROR_1" => "1", "ERROR_2" => "1", "ERROR_3" => "1") do |result|
      expect(result.fetch(:status)).not_to be_success
      expect(result.fetch(:stderr)).to include("provenance errors remain")
      expect(result.fetch(:calls).grep(/ingest:refresh/).length).to eq(3)
      expect(result.fetch(:calls)).not_to include(match(/snapshot:take/))
      expect(result.fetch(:summary)).to include("1 provenance errors in the final attempt")
    end
  end

  it "coalesces an all-registry request into both complete refreshes" do
    run_refresh("REGISTRY" => "all") do |result|
      expect(result.fetch(:status)).to be_success
      expect(result.fetch(:calls)).to include(
        match(/ingest:seed\[rubygems\]/), match(/ingest:seed\[cratesio\]/),
        match(/snapshot:take\[rubygems,2026-09-07\]/),
        match(/snapshot:take\[cratesio,2026-09-07\]/)
      )
    end
  end

  it "retries failed refresh commands and snapshots only after a successful complete batch" do
    run_refresh("REFRESH_1" => "fail", "REFRESH_2" => "fail") do |result|
      expect(result.fetch(:status)).to be_success
      expect(result.fetch(:calls).grep(/ingest:refresh/).length).to eq(3)
      expect(result.fetch(:calls)).to include(match(/snapshot:take/))
    end
  end

  it "fails without a snapshot when all refresh commands fail" do
    run_refresh("REFRESH_1" => "fail", "REFRESH_2" => "fail", "REFRESH_3" => "fail") do |result|
      expect(result.fetch(:status)).not_to be_success
      expect(result.fetch(:calls).grep(/ingest:refresh/).length).to eq(3)
      expect(result.fetch(:calls)).not_to include(match(/snapshot:take/))
      expect(result.fetch(:stderr)).to include("did not complete within its retry budget")
    end
  end

  it "rejects malformed counts and invalid inputs before taking a snapshot" do
    [
      { "REFRESH_1" => "-1" },
      { "ERROR_1" => "null" },
      { "WAIVED_1" => "0.5" },
      { "REGISTRY" => "unknown" },
      { "REFRESH_LIMIT" => "1001" },
      { "PIPELINE_DATE" => "2026-9-7" }
    ].each do |overrides|
      run_refresh(overrides) do |result|
        expect(result.fetch(:status)).not_to be_success
        expect(result.fetch(:calls)).not_to include(match(/snapshot:take/))
      end
    end
  end

  def run_refresh(overrides)
    Dir.mktmpdir("rakkan-refresh-script") do |directory|
      bin = File.join(directory, "bin")
      FileUtils.mkdir_p(bin)
      calls = File.join(directory, "calls")
      state = File.join(directory, "state")
      summary = File.join(directory, "summary")
      File.write(state, "0\n")
      File.write(summary, "")
      File.write(File.join(bin, "bundle"), fake_bundle)
      FileUtils.chmod(0o755, File.join(bin, "bundle"))
      env = {
        "CALLS" => calls,
        "GITHUB_STEP_SUMMARY" => summary,
        "PATH" => "#{bin}:/usr/bin:/bin",
        "PIPELINE_DATE" => "2026-09-07",
        "REFRESH_1" => "0",
        "REFRESH_2" => "0",
        "REFRESH_3" => "0",
        "ERROR_1" => "0",
        "ERROR_2" => "0",
        "ERROR_3" => "0",
        "WAIVED_1" => "0",
        "WAIVED_2" => "0",
        "WAIVED_3" => "0",
        "REFRESH_STATE" => state
      }.merge(overrides)
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, script, chdir: directory, unsetenv_others: true)
      yield(
        status:,
        stdout:,
        stderr:,
        calls: File.file?(calls) ? File.readlines(calls, chomp: true) : [],
        summary: File.read(summary, encoding: "UTF-8")
      )
    end
  end

  def fake_bundle
    <<~'BASH'
      #!/bin/bash
      set -euo pipefail
      printf '%s\n' "$*" >> "${CALLS}"
      if [[ "$*" == *"ingest:refresh"* ]]; then
        if [[ "${REFRESH_OUTPUT+x}" == "x" ]]; then
          printf '%s' "${REFRESH_OUTPUT}"
          exit 0
        fi
        [[ -z "${REFRESH_MESSAGE:-}" ]] || printf '%s\n' "${REFRESH_MESSAGE}"
        count="$(cat "${REFRESH_STATE}")"
        count=$(( count + 1 ))
        printf '%s\n' "${count}" > "${REFRESH_STATE}"
        key="REFRESH_${count}"
        value="${!key}"
        error_key="ERROR_${count}"
        errors="${!error_key}"
        waived_key="WAIVED_${count}"
        waived="${!waived_key}"
        if [[ "${value}" == "fail" ]]; then
          exit 1
        elif [[ "${value}" == "not-json" ]]; then
          printf '%s\n' "${value}"
        else
          printf '{"remaining":%s,"errors":%s,"waived":%s}\n' "${value}" "${errors}" "${waived}"
        fi
      fi
    BASH
  end
end
