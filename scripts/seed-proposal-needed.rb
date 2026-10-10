#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"

module SeedProposal
  SHA = /\A[0-9a-f]{40}\z/

  def self.capture(*command)
    output, status = Open3.capture2(*command, binmode: true)
    raise "#{command.first} failed with status #{status.exitstatus}" unless status.success?

    output.force_encoding(Encoding::UTF_8)
  end

  def self.pages(*)
    result = JSON.parse(capture("gh", "api", "--paginate", "--slurp", *))
    raise "GitHub returned an invalid paginated response" unless result.is_a?(Array) && result.all?(Array)

    result.flatten(1)
  end

  def self.needed?(registry, candidate_dir, automation_branch, names, repository: ENV.fetch("GITHUB_REPOSITORY", ""))
    unless registry.match?(/\A[a-z0-9][a-z0-9_-]*\z/) &&
           automation_branch == "automation/#{registry}-seed" &&
           repository.match?(%r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z})
      raise ArgumentError, "invalid seed proposal identity"
    end
    unless File.directory?(candidate_dir) && !File.symlink?(candidate_dir)
      raise ArgumentError, "candidate seed directory must be a real directory"
    end

    expected_paths = names.map do |name|
      path = File.join(candidate_dir, name)
      unless name.match?(/\A[A-Za-z0-9_.-]+\z/) && File.file?(path) && !File.symlink?(path)
        raise ArgumentError, "candidate seed file is invalid: #{name}"
      end

      "seed/#{registry}/#{name}"
    end
    owner = repository.split("/").first
    pulls = pages("--method", "GET", "repos/#{repository}/pulls",
                  "-f", "state=open", "-f", "base=main", "-f", "head=#{owner}:#{automation_branch}",
                  "-f", "per_page=100").select do |pull|
      pull.dig("head", "repo", "full_name") == repository &&
        pull.dig("head", "ref") == automation_branch && pull.dig("base", "ref") == "main"
    end
    return true if pulls.empty?
    raise "expected at most one open seed proposal, found #{pulls.length}" unless pulls.length == 1

    pull_number = pulls.first["number"]
    head_sha = pulls.first.dig("head", "sha")
    unless pull_number.is_a?(Integer) && pull_number.positive? && head_sha.is_a?(String) && head_sha.match?(SHA)
      raise "open seed proposal has an invalid number or head SHA"
    end

    files = pages("repos/#{repository}/pulls/#{pull_number}/files")
    paths = files.map { |file| file.fetch("filename") }
    unless files.any? && paths.uniq == paths &&
           files.all? { |file| file["status"] == "modified" } &&
           (paths - expected_paths).empty? && paths.include?("seed/#{registry}/manifest.json")
      raise "open seed proposal contains an unexpected file set"
    end

    tree = JSON.parse(capture("gh", "api", "repos/#{repository}/git/trees/#{head_sha}?recursive=1"))
    raise "GitHub returned an invalid or truncated tree" unless tree["truncated"] == false && tree["tree"].is_a?(Array)

    names.zip(expected_paths).any? do |name, path|
      blobs = tree["tree"].select { |entry| entry["path"] == path && entry["type"] == "blob" }
      unless blobs.length == 1 && blobs.first["sha"].is_a?(String) && blobs.first["sha"].match?(SHA)
        raise "open seed proposal has an invalid blob: #{path}"
      end

      capture("git", "hash-object", "--no-filters", "--", File.join(candidate_dir, name)).strip != blobs.first["sha"]
    end
  end
end

if $PROGRAM_NAME == __FILE__
  if ARGV.length < 4
    warn "usage: seed-proposal-needed.rb REGISTRY CANDIDATE_DIR AUTOMATION_BRANCH FILE..."
    exit 2
  end

  begin
    registry, candidate_dir, automation_branch, *names = ARGV
    puts SeedProposal.needed?(registry, candidate_dir, automation_branch, names)
  rescue ArgumentError => e
    warn e.message
    exit 2
  rescue StandardError => e
    warn e.message
    exit 1
  end
end
