# frozen_string_literal: true

require "date"
require "fileutils"
require "json"
require "time"
require "tmpdir"
require "zlib"

module RubygemsSeedBuilder
  module_function

  SOURCE = "rubygems.org weekly public PostgreSQL dump"
  SOURCE_BASE = "https://rubygems-dumps.s3.us-west-2.amazonaws.com"
  BUILT_BY = "research/build_seed.rb"
  TRACKED_SET = "top 1000 gems by total downloads (gem_downloads version_id=0 rows)"
  PACKAGE_HEADER = %w[rank rubygem_id name downloads].freeze
  VERSION_HEADER = %w[
    id number rubygem_id platform created_at indexed prerelease latest
    yanked_at pusher_id pusher_api_key_id
  ].freeze
  ATTESTATION_HEADER = %w[id version_id body media_type created_at updated_at].freeze
  DUMP_KEY = %r{
    \Aproduction/public_postgresql/
    (\d{4})\.(\d{2})\.(\d{2})\.(\d{2})\.(\d{2})\.(\d{2})/
    public_postgresql\.tar\z
  }x

  def dump_timestamp(dump_key)
    match = DUMP_KEY.match(dump_key.to_s)
    raise ArgumentError, "invalid RubyGems dump key" unless match

    year, month, day, hour, minute, second = match.captures.map { |value| Integer(value, 10) }
    unless Date.valid_date?(year, month, day) && hour.between?(0, 23) && minute.between?(0, 59) &&
           second.between?(0, 59)
      raise ArgumentError, "invalid RubyGems dump key"
    end

    Time.utc(year, month, day, hour, minute, second)
  end

  def build(extracted_dir:, seed_dir:, dump_key:, archive_sha256:)
    taken_at = dump_timestamp(dump_key)
    unless archive_sha256.to_s.match?(/\A[0-9a-f]{64}\z/)
      raise ArgumentError, "archive SHA-256 must be 64 lowercase hexadecimal characters"
    end

    parent = File.dirname(File.expand_path(seed_dir))
    FileUtils.mkdir_p(parent)
    result = nil
    Dir.mktmpdir(".rubygems-seed-", parent) do |candidate|
      package_count = copy_packages(extracted_dir, candidate)
      version_ids, version_count = write_versions(extracted_dir, candidate)
      attestation_count = write_attestations(extracted_dir, candidate, version_ids)
      write_manifest(candidate, dump_key, archive_sha256, taken_at)

      FileUtils.mkdir_p(seed_dir)
      expected_files.each do |name|
        FileUtils.mv(File.join(candidate, name), File.join(seed_dir, name))
      end
      result = { packages: package_count, versions: version_count, attestations: attestation_count }
    end
    result
  end

  def expected_files
    %w[manifest.json top_1000.tsv tracked_versions.tsv.gz tracked_attestations.tsv.gz]
  end

  def copy_packages(extracted_dir, candidate)
    source = File.join(extracted_dir, "top_1000.tsv")
    header, *rows = File.readlines(source, encoding: "UTF-8")
    raise ArgumentError, "unexpected top package header" unless header&.chomp&.split("\t") == PACKAGE_HEADER
    raise ArgumentError, "seed must contain exactly 1000 packages" unless rows.length == 1_000

    FileUtils.cp(source, File.join(candidate, "top_1000.tsv"))
    rows.length
  end

  def write_versions(extracted_dir, candidate)
    source = File.join(extracted_dir, "tracked_versions.tsv")
    ids = {}
    count = 0
    File.open(source, encoding: "UTF-8") do |input|
      header = input.gets&.chomp&.split("\t")
      raise ArgumentError, "unexpected tracked version header" unless header == VERSION_HEADER

      gzip_write(File.join(candidate, "tracked_versions.tsv.gz")) do |gzip|
        gzip.puts VERSION_HEADER.join("\t")
        input.each_line do |line|
          fields = line.chomp.split("\t", -1)
          raise ArgumentError, "tracked version row has the wrong width" unless fields.length == VERSION_HEADER.length
          raise ArgumentError, "duplicate tracked version id #{fields.first}" if ids[fields.first]

          ids[fields.first] = true
          gzip.puts fields.join("\t")
          count += 1
        end
      end
    end
    raise ArgumentError, "tracked version seed must not be empty" if count.zero?

    [ids, count]
  end

  def write_attestations(extracted_dir, candidate, version_ids)
    columns = File.read(File.join(extracted_dir, "attestations.columns"), encoding: "UTF-8").chomp.split("\t", -1)
    missing = ATTESTATION_HEADER - columns
    raise ArgumentError, "attestations COPY is missing columns: #{missing.join(", ")}" unless missing.empty?

    indexes = ATTESTATION_HEADER.map { |column| columns.index(column) }
    ids = {}
    kept = 0

    gzip_write(File.join(candidate, "tracked_attestations.tsv.gz")) do |gzip|
      gzip.puts ATTESTATION_HEADER.join("\t")
      File.foreach(File.join(extracted_dir, "attestations.tsv"), encoding: "UTF-8") do |line|
        fields = line.chomp.split("\t", -1)
        unless fields.length == columns.length
          raise ArgumentError,
                "attestation row width does not match its COPY schema"
        end

        selected = indexes.map { |index| fields.fetch(index) }
        next unless version_ids[selected[1]]
        raise ArgumentError, "duplicate attestation id #{selected.first}" if ids[selected.first]

        ids[selected.first] = true
        gzip.puts selected.join("\t")
        kept += 1
      end
    end
    kept
  end

  def write_manifest(candidate, dump_key, archive_sha256, taken_at)
    manifest = {
      source: SOURCE,
      source_url: "#{SOURCE_BASE}/#{dump_key}",
      dump_key:,
      dump_taken_at: taken_at.iso8601,
      archive_sha256:,
      built_by: BUILT_BY,
      tracked_set: TRACKED_SET
    }
    File.write(File.join(candidate, "manifest.json"), "#{JSON.pretty_generate(manifest)}\n", encoding: "UTF-8")
  end

  def gzip_write(path)
    Zlib::GzipWriter.open(path, external_encoding: "UTF-8") do |gzip|
      gzip.mtime = 0
      yield gzip
    end
  end
end

if $PROGRAM_NAME == __FILE__
  extracted_dir, seed_dir, dump_key, archive_sha256 = ARGV
  unless extracted_dir && seed_dir && dump_key && archive_sha256
    abort "usage: build_seed.rb <extracted-dir> <seed-dir> <dump-key> <archive-sha256>"
  end

  result = RubygemsSeedBuilder.build(extracted_dir:, seed_dir:, dump_key:, archive_sha256:)
  puts JSON.generate(result)
end
