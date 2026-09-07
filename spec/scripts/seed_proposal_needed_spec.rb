# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "tmpdir"

RSpec.describe "seed-proposal-needed.sh" do
  let(:script) { Hanami.app.root.join("scripts", "seed-proposal-needed.sh").to_s }

  def blob_sha(content)
    Digest::SHA1.hexdigest("blob #{content.bytesize}\0#{content}")
  end

  def run_check(pulls:, files: [], content: "candidate\n", remote_content: content)
    Dir.mktmpdir("rakkan-seed-proposal") do |directory|
      candidate = File.join(directory, "candidate")
      bin = File.join(directory, "bin")
      FileUtils.mkdir_p([candidate, bin])
      File.write(File.join(candidate, "manifest.json"), content)
      File.write(File.join(candidate, "top_1000.tsv"), "top\n")
      File.write(File.join(bin, "gh"), fake_gh)
      FileUtils.chmod(0o755, File.join(bin, "gh"))
      tree = {
        "truncated" => false,
        "tree" => [
          {
            "path" => "seed/rubygems/manifest.json",
            "type" => "blob",
            "sha" => blob_sha(remote_content)
          },
          {
            "path" => "seed/rubygems/top_1000.tsv",
            "type" => "blob",
            "sha" => blob_sha("top\n")
          }
        ]
      }
      env = {
        "FILES_JSON" => JSON.generate([files]),
        "GITHUB_REPOSITORY" => "starhaven-io/rakkan",
        "PATH" => "#{bin}:#{ENV.fetch("PATH")}",
        "PRS_JSON" => JSON.generate([pulls]),
        "TREE_JSON" => JSON.generate(tree)
      }
      yield Open3.capture3(
        env, "bash", script, "rubygems", candidate, "automation/rubygems-seed",
        "manifest.json", "top_1000.tsv",
        chdir: Hanami.app.root.to_s
      )
    end
  end

  def open_pull(number: 42, repository: "starhaven-io/rakkan")
    {
      "number" => number,
      "head" => {
        "sha" => "a" * 40,
        "ref" => "automation/rubygems-seed",
        "repo" => { "full_name" => repository }
      },
      "base" => { "ref" => "main" }
    }
  end

  def expected_files
    [{ "filename" => "seed/rubygems/manifest.json", "status" => "modified" }]
  end

  it "leaves an identical open proposal untouched" do
    run_check(pulls: [open_pull], files: expected_files) do |stdout, stderr, status|
      expect(status).to be_success
      expect(stdout).to eq("false\n")
      expect(stderr).to be_empty
    end
  end

  it "requests an update when the candidate bytes differ or no proposal exists" do
    run_check(pulls: [open_pull], files: expected_files, remote_content: "older\n") do |stdout, _stderr, status|
      expect(status).to be_success
      expect(stdout).to eq("true\n")
    end
    run_check(pulls: []) do |stdout, _stderr, status|
      expect(status).to be_success
      expect(stdout).to eq("true\n")
    end
  end

  it "fails closed when an open proposal has unexpected files" do
    files = expected_files + [{ "filename" => "README.md", "status" => "modified" }]
    run_check(pulls: [open_pull], files:) do |_stdout, stderr, status|
      expect(status).not_to be_success
      expect(stderr).to include("unexpected file set")
    end
  end

  it "requires the manifest while allowing an unchanged seed file to be absent from the diff" do
    run_check(pulls: [open_pull], files: expected_files) do |stdout, _stderr, status|
      expect(status).to be_success
      expect(stdout).to eq("false\n")
    end

    files = [{ "filename" => "seed/rubygems/top_1000.tsv", "status" => "modified" }]
    run_check(pulls: [open_pull], files:) do |_stdout, stderr, status|
      expect(status).not_to be_success
      expect(stderr).to include("unexpected file set")
    end
  end

  it "ignores same-named automation branches from forks" do
    fork_pull = open_pull(number: 7, repository: "starhaven-io/rakkan-fork")
    run_check(pulls: [fork_pull]) do |stdout, _stderr, status|
      expect(status).to be_success
      expect(stdout).to eq("true\n")
    end

    run_check(pulls: [fork_pull, open_pull], files: expected_files) do |stdout, _stderr, status|
      expect(status).to be_success
      expect(stdout).to eq("false\n")
    end
  end

  def fake_gh
    <<~'BASH'
      #!/usr/bin/env bash
      set -euo pipefail
      if [[ "$*" == *"/pulls/"*"/files"* ]]; then
        printf '%s\n' "${FILES_JSON}"
      elif [[ "$*" == *"/git/trees/"* ]]; then
        printf '%s\n' "${TREE_JSON}"
      elif [[ "$*" == *"repos/starhaven-io/rakkan/pulls"* ]]; then
        printf '%s\n' "${PRS_JSON}"
      else
        exit 64
      fi
    BASH
  end
end
