# frozen_string_literal: true

require "digest"
require "json"
require "time"
require "zlib"
require_relative "build_cratesio_seed"

module CratesioSeedUpdate
  module_function

  MAX_DUMP_AGE = 2 * 24 * 60 * 60
  MAX_CLOCK_SKEW = 5 * 60
  PACKAGE_HEADER = "rank\tcrate_id\tname\tdownloads\n"
  VERSION_HEADER = "id\tnumber\tcrate_id\tcreated_at\tprerelease\tlatest\tyanked\n"
  MANIFEST_FIELDS = {
    "source" => "crates.io daily database dump",
    "source_url" => CratesioSeedBuilder::SOURCE_URL,
    "built_by" => "research/build_cratesio_seed.rb",
    "tracked_set" => "top 1000 crates by total downloads (crate_downloads.csv)",
    "provenance" => "not present in the database dump; seeded versions remain unchecked"
  }.freeze

  def check(current_seed:, candidate_seed:, now: Time.now.utc)
    current_manifest = manifest(current_seed)
    candidate_manifest = manifest(candidate_seed)
    validate_manifest(current_manifest, "current")
    validate_manifest(candidate_manifest, "candidate")
    current_taken_at = timestamp(current_manifest, "current")
    candidate_taken_at = timestamp(candidate_manifest, "candidate")

    unless candidate_taken_at > current_taken_at
      raise ArgumentError, "candidate dump is not newer than the committed seed"
    end
    if now - candidate_taken_at > MAX_DUMP_AGE
      raise ArgumentError, "candidate dump is more than #{MAX_DUMP_AGE / 86_400} days old"
    end
    raise ArgumentError, "candidate dump timestamp is in the future" if candidate_taken_at - now > MAX_CLOCK_SKEW

    current = fingerprint(current_seed)
    candidate = fingerprint(candidate_seed)

    {
      update_required: current.values_at(:packages_sha256, :versions_sha256) !=
        candidate.values_at(:packages_sha256, :versions_sha256),
      dump_taken_at: candidate_manifest.fetch("dump_taken_at"),
      source_commit: candidate_manifest.fetch("source_commit"),
      packages: candidate.fetch(:packages),
      versions: candidate.fetch(:versions),
      packages_sha256: candidate.fetch(:packages_sha256),
      versions_sha256: candidate.fetch(:versions_sha256)
    }
  end

  def manifest(seed_dir)
    payload = JSON.parse(File.read(File.join(seed_dir, "manifest.json"), encoding: "UTF-8"))
    raise ArgumentError, "seed manifest must be an object" unless payload.is_a?(Hash)

    payload
  rescue Errno::ENOENT, JSON::ParserError => e
    raise ArgumentError, "invalid seed manifest: #{e.message}"
  end

  def timestamp(manifest, label)
    Time.iso8601(manifest.fetch("dump_taken_at"))
  rescue KeyError, ArgumentError
    raise ArgumentError, "#{label} seed has an invalid dump_taken_at"
  end

  def validate_manifest(manifest, label)
    MANIFEST_FIELDS.each do |field, expected|
      next if manifest[field] == expected

      raise ArgumentError, "#{label} seed has an unexpected #{field}"
    end
    return if manifest["source_commit"].to_s.match?(/\A[0-9a-f]{40}\z/)

    raise ArgumentError, "#{label} seed has an invalid source commit"
  end

  def fingerprint(seed_dir)
    packages_path = File.join(seed_dir, "top_1000.tsv")
    versions_path = File.join(seed_dir, "tracked_versions.tsv.gz")
    packages = row_count(packages_path, PACKAGE_HEADER)
    raise ArgumentError, "seed must contain exactly 1000 packages" unless packages == 1_000

    versions, versions_sha256 = gzip_fingerprint(versions_path)
    raise ArgumentError, "seed must contain at least one version" unless versions.positive?

    {
      packages:,
      versions:,
      packages_sha256: Digest::SHA256.file(packages_path).hexdigest,
      versions_sha256:
    }
  rescue Errno::ENOENT, Zlib::GzipFile::Error => e
    raise ArgumentError, "invalid seed data: #{e.message}"
  end

  def row_count(path, expected_header)
    File.open(path, "r", encoding: "UTF-8") do |file|
      raise ArgumentError, "unexpected header in #{File.basename(path)}" unless file.gets == expected_header

      file.each_line.count
    end
  end

  def gzip_fingerprint(path)
    digest = Digest::SHA256.new
    rows = 0
    Zlib::GzipReader.open(path, external_encoding: "UTF-8") do |gzip|
      header = gzip.gets
      raise ArgumentError, "unexpected header in #{File.basename(path)}" unless header == VERSION_HEADER

      digest.update(header)
      gzip.each_line do |line|
        digest.update(line)
        rows += 1
      end
    end
    [rows, digest.hexdigest]
  end
end

if $PROGRAM_NAME == __FILE__
  current_seed, candidate_seed = ARGV
  unless current_seed && candidate_seed
    abort "usage: check_cratesio_seed_update.rb <current-seed-dir> <candidate-seed-dir>"
  end

  begin
    puts JSON.generate(CratesioSeedUpdate.check(current_seed:, candidate_seed:))
  rescue ArgumentError => e
    warn "crates.io seed update check failed: #{e.message}"
    exit 1
  end
end
