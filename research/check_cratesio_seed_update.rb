# frozen_string_literal: true

require "digest"
require "json"
require "time"
require "zlib"
require_relative "build_cratesio_seed"

module CratesioSeedUpdate
  module_function

  MAX_DUMP_AGE = 2 * 24 * 60 * 60
  MAX_CURRENT_DUMP_AGE = 9 * 24 * 60 * 60
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
    validate_freshness(candidate_taken_at, now:, max_age: MAX_DUMP_AGE, label: "candidate")

    current = fingerprint(current_seed, dump_taken_at: current_taken_at)
    candidate = fingerprint(candidate_seed, dump_taken_at: candidate_taken_at)
    content_changed = current.values_at(:packages_sha256, :versions_sha256) !=
                      candidate.values_at(:packages_sha256, :versions_sha256)
    source_fields = %w[dump_taken_at source_url source_commit archive_sha256]
    source_changed = current_manifest.values_at(*source_fields) != candidate_manifest.values_at(*source_fields)
    raise ArgumentError, "candidate dump is older than the committed seed" if candidate_taken_at < current_taken_at
    if candidate_taken_at == current_taken_at && (content_changed || source_changed)
      raise ArgumentError, "candidate dump reuses the committed timestamp with different data"
    end

    {
      update_required: content_changed || source_changed,
      content_changed:,
      dump_taken_at: candidate_manifest.fetch("dump_taken_at"),
      source_commit: candidate_manifest.fetch("source_commit"),
      packages: candidate.fetch(:packages),
      versions: candidate.fetch(:versions),
      packages_sha256: candidate.fetch(:packages_sha256),
      versions_sha256: candidate.fetch(:versions_sha256)
    }
  end

  def validate_current(seed_dir:, now: Time.now.utc, require_fresh: true)
    payload = manifest(seed_dir)
    validate_manifest(payload, "current")
    taken_at = timestamp(payload, "current")
    max_age = require_fresh ? MAX_CURRENT_DUMP_AGE : nil
    validate_freshness(taken_at, now:, max_age:, label: "current")
    fingerprint(seed_dir, dump_taken_at: taken_at)
    { dump_taken_at: payload.fetch("dump_taken_at") }
  end

  def validate_freshness(taken_at, now:, max_age:, label:)
    if max_age && now - taken_at > max_age
      raise ArgumentError, "#{label} dump is more than #{max_age / 86_400} days old"
    end
    raise ArgumentError, "#{label} dump timestamp is in the future" if taken_at - now > MAX_CLOCK_SKEW
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
    unless manifest["source_commit"].to_s.match?(/\A[0-9a-f]{40}\z/)
      raise ArgumentError, "#{label} seed has an invalid source commit"
    end
    return if manifest["archive_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)

    raise ArgumentError, "#{label} seed has an invalid archive SHA-256"
  end

  def fingerprint(seed_dir, dump_taken_at:)
    packages_path = File.join(seed_dir, "top_1000.tsv")
    versions_path = File.join(seed_dir, "tracked_versions.tsv.gz")
    package_ids, packages = validate_packages(packages_path)
    versions, versions_sha256 = validate_versions(versions_path, package_ids, dump_taken_at)
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

  def validate_packages(path)
    ids = {}
    names = {}
    previous = nil
    count = 0
    File.open(path, "r", encoding: "UTF-8") do |file|
      raise ArgumentError, "unexpected header in #{File.basename(path)}" unless file.gets == PACKAGE_HEADER

      file.each_line do |line|
        fields = line.chomp.split("\t", -1)
        raise ArgumentError, "package row has the wrong width" unless fields.length == 4

        rank = Integer(fields[0], 10)
        id = fields[1]
        name = fields[2]
        downloads = Integer(fields[3], 10)
        raise ArgumentError, "package ranks must be contiguous" unless rank == count + 1
        raise ArgumentError, "package ids and names must not be empty" if id.empty? || name.empty?
        raise ArgumentError, "duplicate package id #{id}" if ids[id]
        raise ArgumentError, "duplicate package name #{name}" if names[name]
        raise ArgumentError, "package downloads must be non-negative" if downloads.negative?
        if previous && (downloads > previous[0] || (downloads == previous[0] && name < previous[1]))
          raise ArgumentError, "packages are not deterministically download-ranked"
        end

        ids[id] = true
        names[name] = true
        previous = [downloads, name]
        count += 1
      end
    end
    raise ArgumentError, "seed must contain exactly 1000 packages" unless count == 1_000

    [ids, count]
  end

  def validate_versions(path, package_ids, dump_taken_at)
    digest = Digest::SHA256.new
    rows = 0
    ids = {}
    natural_keys = {}
    latest_by_package = Hash.new(0)
    versions_by_package = Hash.new(0)
    Zlib::GzipReader.open(path, external_encoding: "UTF-8") do |gzip|
      header = gzip.gets
      raise ArgumentError, "unexpected header in #{File.basename(path)}" unless header == VERSION_HEADER

      digest.update(header)
      gzip.each_line do |line|
        fields = line.chomp.split("\t", -1)
        raise ArgumentError, "version row has the wrong width" unless fields.length == 7

        id, number, package_id, created_at, prerelease, latest, yanked = fields
        raise ArgumentError, "version identifiers must not be empty" if [id, number, package_id].any?(&:empty?)
        raise ArgumentError, "duplicate version id #{id}" if ids[id]
        raise ArgumentError, "version references an untracked package" unless package_ids[package_id]

        key = [package_id, number]
        raise ArgumentError, "duplicate package version #{key.join("/")}" if natural_keys[key]

        %w[true false].tap do |booleans|
          raise ArgumentError, "version flags must be true or false" unless [prerelease, latest, yanked].all? do |v|
            booleans.include?(v)
          end
        end
        expected_prerelease = CratesioSeedBuilder.prerelease?(number).to_s
        raise ArgumentError, "prerelease flag does not match the version" unless prerelease == expected_prerelease

        timestamp = Time.parse("#{created_at} UTC")
        raise ArgumentError, "version timestamp is after the dump" if timestamp > dump_taken_at + MAX_CLOCK_SKEW

        ids[id] = true
        natural_keys[key] = true
        versions_by_package[package_id] += 1
        latest_by_package[package_id] += 1 if latest == "true"
        digest.update(line)
        rows += 1
      end
    end
    missing = package_ids.keys - versions_by_package.keys
    raise ArgumentError, "#{missing.length} tracked packages have no versions" unless missing.empty?

    package_ids.each_key do |package_id|
      unless latest_by_package[package_id] == 1
        raise ArgumentError,
              "package #{package_id} must have exactly one latest version"
      end
    end
    [rows, digest.hexdigest]
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    if %w[--current --structural].include?(ARGV.first)
      mode = ARGV.first
      seed_dir = ARGV[1]
      abort "usage: check_cratesio_seed_update.rb [--current|--structural] <seed-dir>" unless seed_dir
      puts JSON.generate(
        CratesioSeedUpdate.validate_current(seed_dir:, require_fresh: mode == "--current")
      )
    else
      current_seed, candidate_seed = ARGV
      unless current_seed && candidate_seed
        abort "usage: check_cratesio_seed_update.rb <current-seed-dir> <candidate-seed-dir>"
      end
      puts JSON.generate(CratesioSeedUpdate.check(current_seed:, candidate_seed:))
    end
  rescue ArgumentError => e
    warn "crates.io seed update check failed: #{e.message}"
    exit 1
  end
end
