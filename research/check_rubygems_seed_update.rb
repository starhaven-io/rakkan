# frozen_string_literal: true

require "csv"
require "digest"
require "json"
require "rubygems/version"
require "time"
require "zlib"
require_relative "build_seed"
require_relative "../slices/ingestion/http_client"
require_relative "../slices/ingestion/adapters/rubygems/attestation"

module RubygemsSeedUpdate
  module_function

  MAX_DUMP_AGE = 9 * 24 * 60 * 60
  MAX_CLOCK_SKEW = 5 * 60
  MANIFEST_FIELDS = {
    "source" => RubygemsSeedBuilder::SOURCE,
    "built_by" => RubygemsSeedBuilder::BUILT_BY,
    "tracked_set" => RubygemsSeedBuilder::TRACKED_SET
  }.freeze

  def check(current_seed:, candidate_seed:, now: Time.now.utc)
    current_manifest = manifest(current_seed)
    candidate_manifest = manifest(candidate_seed)
    validate_manifest(current_manifest, "current")
    validate_manifest(candidate_manifest, "candidate")
    current_taken_at = timestamp(current_manifest, "current")
    candidate_taken_at = timestamp(candidate_manifest, "candidate")
    validate_freshness(candidate_taken_at, now:)

    current = fingerprint(current_seed, dump_taken_at: current_taken_at)
    candidate = fingerprint(candidate_seed, dump_taken_at: candidate_taken_at)
    content_keys = %i[packages_sha256 versions_sha256 attestations_sha256]
    content_changed = current.values_at(*content_keys) != candidate.values_at(*content_keys)
    source_fields = %w[dump_taken_at dump_key source_url archive_sha256]
    source_changed = current_manifest.values_at(*source_fields) != candidate_manifest.values_at(*source_fields)
    raise ArgumentError, "candidate dump is older than the committed seed" if candidate_taken_at < current_taken_at
    if candidate_taken_at == current_taken_at && (content_changed || source_changed)
      raise ArgumentError, "candidate dump reuses the committed timestamp with different data"
    end

    {
      update_required: content_changed || source_changed,
      content_changed:,
      dump_taken_at: candidate_manifest.fetch("dump_taken_at"),
      dump_key: candidate_manifest.fetch("dump_key"),
      packages: candidate.fetch(:packages),
      versions: candidate.fetch(:versions),
      attestations: candidate.fetch(:attestations),
      packages_sha256: candidate.fetch(:packages_sha256),
      versions_sha256: candidate.fetch(:versions_sha256),
      attestations_sha256: candidate.fetch(:attestations_sha256)
    }
  end

  def validate_current(seed_dir:, now: Time.now.utc, require_fresh: true)
    payload = manifest(seed_dir)
    validate_manifest(payload, "current")
    taken_at = timestamp(payload, "current")
    validate_freshness(taken_at, now:, max_age: require_fresh ? MAX_DUMP_AGE : nil)
    fingerprint(seed_dir, dump_taken_at: taken_at)
    { dump_taken_at: payload.fetch("dump_taken_at") }
  end

  def manifest(seed_dir)
    payload = JSON.parse(File.read(File.join(seed_dir, "manifest.json"), encoding: "UTF-8"))
    raise ArgumentError, "seed manifest must be an object" unless payload.is_a?(Hash)

    payload
  rescue Errno::ENOENT, JSON::ParserError => e
    raise ArgumentError, "invalid seed manifest: #{e.message}"
  end

  def timestamp(payload, label)
    Time.iso8601(payload.fetch("dump_taken_at"))
  rescue KeyError, ArgumentError
    raise ArgumentError, "#{label} seed has an invalid dump_taken_at"
  end

  def validate_manifest(payload, label)
    MANIFEST_FIELDS.each do |field, expected|
      raise ArgumentError, "#{label} seed has an unexpected #{field}" unless payload[field] == expected
    end
    key = payload["dump_key"].to_s
    begin
      expected_taken_at = RubygemsSeedBuilder.dump_timestamp(key).iso8601
    rescue ArgumentError
      raise ArgumentError, "#{label} seed has an invalid dump key"
    end
    unless payload["dump_taken_at"] == expected_taken_at
      raise ArgumentError, "#{label} seed dump_taken_at does not match its dump key"
    end

    expected_url = "#{RubygemsSeedBuilder::SOURCE_BASE}/#{key}"
    raise ArgumentError, "#{label} seed has an unexpected source URL" unless payload["source_url"] == expected_url
    return if payload["archive_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)

    raise ArgumentError, "#{label} seed has an invalid archive SHA-256"
  end

  def validate_freshness(taken_at, now:, max_age: MAX_DUMP_AGE)
    raise ArgumentError, "dump is more than #{max_age / 86_400} days old" if max_age && now - taken_at > max_age
    raise ArgumentError, "dump timestamp is in the future" if taken_at - now > MAX_CLOCK_SKEW
  end

  def fingerprint(seed_dir, dump_taken_at:)
    package_ids, packages, packages_sha256 = validate_packages(File.join(seed_dir, "top_1000.tsv"))
    version_ids, versions, versions_sha256 = validate_versions(
      File.join(seed_dir, "tracked_versions.tsv.gz"), package_ids, dump_taken_at
    )
    attestations, attestations_sha256 = validate_attestations(
      File.join(seed_dir, "tracked_attestations.tsv.gz"), version_ids, dump_taken_at
    )
    {
      packages:, versions:, attestations:,
      packages_sha256:, versions_sha256:, attestations_sha256:
    }
  rescue Errno::ENOENT, Zlib::GzipFile::Error, CSV::MalformedCSVError => e
    raise ArgumentError, "invalid seed data: #{e.message}"
  end

  def validate_packages(path)
    rows = CSV.read(path, headers: true, col_sep: "\t", encoding: "UTF-8")
    raise ArgumentError, "unexpected package header" unless rows.headers == RubygemsSeedBuilder::PACKAGE_HEADER
    raise ArgumentError, "seed must contain exactly 1000 packages" unless rows.length == 1_000

    ids = {}
    names = {}
    previous = nil
    rows.each_with_index do |row, index|
      rank = Integer(row.fetch("rank"), 10)
      id = required(row, "rubygem_id")
      name = required(row, "name")
      downloads = Integer(row.fetch("downloads"), 10)
      raise ArgumentError, "package ranks must be contiguous" unless rank == index + 1
      raise ArgumentError, "duplicate package id #{id}" if ids[id]
      raise ArgumentError, "duplicate package name #{name}" if names[name]
      raise ArgumentError, "package downloads must be non-negative" if downloads.negative?
      if previous && (downloads > previous[0] || (downloads == previous[0] && name < previous[1]))
        raise ArgumentError, "packages are not deterministically download-ranked"
      end

      ids[id] = true
      names[name] = true
      previous = [downloads, name]
    end
    [ids, rows.length, Digest::SHA256.file(path).hexdigest]
  end

  def validate_versions(path, package_ids, dump_taken_at)
    ids = {}
    natural_keys = {}
    latest_counts = Hash.new(0)
    package_counts = Hash.new(0)
    rows, digest = each_gzip_row(path, RubygemsSeedBuilder::VERSION_HEADER) do |fields|
      row = RubygemsSeedBuilder::VERSION_HEADER.zip(fields).to_h
      id = required(row, "id")
      package_id = required(row, "rubygem_id")
      number = required(row, "number")
      platform = required(row, "platform")
      published_at = parse_timestamp(required(row, "created_at"), "created_at")
      raise ArgumentError, "version references an untracked package" unless package_ids[package_id]
      raise ArgumentError, "duplicate version id #{id}" if ids[id]

      key = [package_id, number, platform]
      raise ArgumentError, "duplicate package version #{key.join("/")}" if natural_keys[key]
      raise ArgumentError, "version timestamp is after the dump" if published_at > dump_taken_at + MAX_CLOCK_SKEW

      %w[indexed prerelease latest].each { |field| validate_postgres_boolean(row.fetch(field), field) }
      expected_prerelease = Gem::Version.new(number).prerelease? ? "t" : "f"
      unless row.fetch("prerelease") == expected_prerelease
        raise ArgumentError,
              "prerelease flag does not match the version"
      end

      yanked_at = row.fetch("yanked_at")
      unless yanked_at == "\\N"
        yanked_at = parse_timestamp(yanked_at, "yanked_at")
        raise ArgumentError, "yanked_at is after the dump" if yanked_at > dump_taken_at + MAX_CLOCK_SKEW
      end

      ids[id] = true
      natural_keys[key] = true
      package_counts[package_id] += 1
      latest_counts[package_id] += 1 if row.fetch("latest") == "t"
    end
    missing = package_ids.keys - package_counts.keys
    raise ArgumentError, "#{missing.length} tracked packages have no versions" unless missing.empty?

    missing_latest = package_ids.keys - latest_counts.keys
    raise ArgumentError, "#{missing_latest.length} tracked packages have no latest version" unless missing_latest.empty?

    [ids, rows, digest]
  end

  def validate_attestations(path, version_ids, dump_taken_at)
    ids = {}
    each_gzip_row(path, RubygemsSeedBuilder::ATTESTATION_HEADER) do |fields|
      row = RubygemsSeedBuilder::ATTESTATION_HEADER.zip(fields).to_h
      id = required(row, "id")
      raise ArgumentError, "duplicate attestation id #{id}" if ids[id]
      raise ArgumentError, "attestation references an untracked version" unless version_ids[row.fetch("version_id")]

      body = parse_json_object(unescape_copy(required(row, "body")), "attestation body")
      media_type = required(row, "media_type")
      raise ArgumentError, "attestation media type does not match its body" unless body["mediaType"] == media_type

      begin
        Ingestion::Adapters::Rubygems::Attestation.parse([body])
      rescue Ingestion::HTTPClient::InvalidDataError => e
        raise ArgumentError, "attestation body is not parseable: #{e.message}"
      end

      created_at = parse_timestamp(required(row, "created_at"), "attestation created_at")
      updated_at = parse_timestamp(required(row, "updated_at"), "attestation updated_at")
      if [created_at, updated_at].any? { |timestamp| timestamp > dump_taken_at + MAX_CLOCK_SKEW }
        raise ArgumentError, "attestation timestamp is after the dump"
      end
      raise ArgumentError, "attestation updated_at is before created_at" if updated_at < created_at

      ids[id] = true
    end
  end

  def each_gzip_row(path, expected_header)
    digest = Digest::SHA256.new
    count = 0
    Zlib::GzipReader.open(path, external_encoding: "UTF-8") do |gzip|
      header = gzip.gets
      expected = "#{expected_header.join("\t")}\n"
      raise ArgumentError, "unexpected header in #{File.basename(path)}" unless header == expected

      digest.update(header)
      gzip.each_line do |line|
        fields = line.chomp.split("\t", -1)
        unless fields.length == expected_header.length
          raise ArgumentError,
                "row width does not match #{File.basename(path)}"
        end

        digest.update(line)
        yield fields
        count += 1
      end
    end
    [count, digest.hexdigest]
  end

  def required(row, field)
    value = row.fetch(field)
    raise ArgumentError, "#{field} must not be empty" if value.nil? || value.empty? || value == "\\N"

    value
  end

  def validate_postgres_boolean(value, field)
    raise ArgumentError, "#{field} must be t or f" unless %w[t f].include?(value)
  end

  def parse_timestamp(value, field)
    Time.parse("#{value} UTC")
  rescue ArgumentError
    raise ArgumentError, "#{field} must be a timestamp"
  end

  def parse_json_object(value, field)
    parsed = JSON.parse(value)
    return parsed if parsed.is_a?(Hash)

    raise ArgumentError, "#{field} must be an object"
  rescue JSON::ParserError
    raise ArgumentError, "#{field} must be valid JSON"
  end

  COPY_ESCAPES = { "\\\\" => "\\", "\\t" => "\t", "\\n" => "\n", "\\r" => "\r" }.freeze

  def unescape_copy(value)
    value.gsub(/\\[\\tnr]/, COPY_ESCAPES)
  end
end

if $PROGRAM_NAME == __FILE__
  mode = ARGV.first
  begin
    if %w[--current --structural].include?(mode)
      seed_dir = ARGV[1]
      abort "usage: check_rubygems_seed_update.rb [--current|--structural] <seed-dir>" unless seed_dir
      puts JSON.generate(
        RubygemsSeedUpdate.validate_current(seed_dir:, require_fresh: mode == "--current")
      )
    else
      current_seed, candidate_seed = ARGV
      unless current_seed && candidate_seed
        abort "usage: check_rubygems_seed_update.rb <current-seed-dir> <candidate-seed-dir>"
      end
      puts JSON.generate(RubygemsSeedUpdate.check(current_seed:, candidate_seed:))
    end
  rescue ArgumentError => e
    warn "RubyGems seed update check failed: #{e.message}"
    exit 1
  end
end
