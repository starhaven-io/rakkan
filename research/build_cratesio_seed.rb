# frozen_string_literal: true

# Distill an extracted crates.io daily database dump into deterministic seed
# inputs. The dump provides package/version state but no trusted-publishing
# metadata, so this builder deliberately emits no provenance observations.
#
# Usage: ruby research/build_cratesio_seed.rb <dump-dir> <seed-dir> <archive-sha256> [<limit>]
#
# <dump-dir> is the dated directory at the root of db-dump.tar.gz. It must
# contain metadata.json and data/{crate_downloads,crates,default_versions,versions}.csv.

require "csv"
require "fileutils"
require "json"
require "zlib"

module CratesioSeedBuilder
  module_function

  SOURCE_URL = "https://static.crates.io/db-dump.tar.gz"
  TRUTHY = %w[1 t true].freeze
  FALSEY = %w[0 f false].freeze

  def build(dump_dir:, seed_dir:, archive_sha256:, limit: 1_000)
    limit = Integer(limit)
    raise ArgumentError, "limit must be positive" unless limit.positive?
    raise ArgumentError, "invalid archive SHA-256" unless archive_sha256.to_s.match?(/\A[0-9a-f]{64}\z/)

    data_dir = File.join(dump_dir, "data")
    metadata = JSON.parse(File.read(File.join(dump_dir, "metadata.json"), encoding: "UTF-8"))
    downloads = downloads_by_crate(File.join(data_dir, "crate_downloads.csv"))
    tracked = top_crates(File.join(data_dir, "crates.csv"), downloads, limit)
    tracked_ids = tracked.to_h { |crate| [crate.fetch("id"), true] }
    default_versions = default_versions_by_crate(
      File.join(data_dir, "default_versions.csv"), tracked_ids
    )

    FileUtils.mkdir_p(seed_dir)
    write_manifest(seed_dir, metadata, limit, archive_sha256)
    write_tracked_packages(seed_dir, tracked)
    versions = write_versions(
      seed_dir,
      File.join(data_dir, "versions.csv"),
      tracked_ids,
      default_versions
    )

    { packages: tracked.size, versions: versions }
  end

  def downloads_by_crate(path)
    CSV.foreach(path, headers: true, encoding: "UTF-8").each_with_object({}) do |row, downloads|
      crate_id = row.fetch("crate_id")
      raise ArgumentError, "duplicate download total for crate #{crate_id}" if downloads.key?(crate_id)

      count = Integer(row.fetch("downloads"), 10)
      raise ArgumentError, "crate download totals must be non-negative" if count.negative?

      downloads[crate_id] = count
    end
  end

  def top_crates(path, downloads, limit)
    ids = {}
    names = {}
    crates = CSV.foreach(path, headers: true, encoding: "UTF-8").filter_map do |row|
      id = row.fetch("id")
      name = row.fetch("name")
      raise ArgumentError, "crate identifiers and names must not be empty" if id.empty? || name.empty?
      raise ArgumentError, "duplicate crate id #{id}" if ids[id]
      raise ArgumentError, "duplicate crate name #{name}" if names[name]

      ids[id] = true
      names[name] = true
      crate_downloads = downloads[id]
      next unless crate_downloads

      { "id" => id, "name" => name, "downloads" => crate_downloads }
    end
    tracked = crates.sort_by { |crate| [-crate.fetch("downloads"), crate.fetch("name")] }.first(limit)
    if tracked.length < limit
      raise ArgumentError, "dump contains only #{tracked.length} ranked crates; expected #{limit}"
    end

    tracked
  end

  def default_versions_by_crate(path, tracked_ids)
    CSV.foreach(path, headers: true, encoding: "UTF-8").each_with_object({}) do |row, versions|
      crate_id = row.fetch("crate_id")
      next unless tracked_ids[crate_id]
      raise ArgumentError, "duplicate default version for crate #{crate_id}" if versions.key?(crate_id)

      versions[crate_id] = row.fetch("version_id")
    end
  end

  def write_manifest(seed_dir, metadata, limit, archive_sha256)
    manifest = {
      source: "crates.io daily database dump",
      source_url: SOURCE_URL,
      archive_sha256: archive_sha256,
      dump_taken_at: metadata.fetch("timestamp"),
      source_commit: metadata.fetch("crates_io_commit"),
      built_by: "research/build_cratesio_seed.rb",
      tracked_set: "top #{limit} crates by total downloads (crate_downloads.csv)",
      provenance: "not present in the database dump; seeded versions remain unchecked"
    }
    File.write(File.join(seed_dir, "manifest.json"), "#{JSON.pretty_generate(manifest)}\n")
  end

  def write_tracked_packages(seed_dir, tracked)
    File.open(File.join(seed_dir, "top_1000.tsv"), "w", encoding: "UTF-8") do |file|
      file.puts %w[rank crate_id name downloads].join("\t")
      tracked.each_with_index do |crate, index|
        file.puts [index + 1, crate.fetch("id"), crate.fetch("name"), crate.fetch("downloads")].join("\t")
      end
    end
  end

  def write_versions(seed_dir, path, tracked_ids, default_versions)
    count = 0
    Zlib::GzipWriter.open(File.join(seed_dir, "tracked_versions.tsv.gz"), external_encoding: "UTF-8") do |gzip|
      gzip.mtime = 0
      gzip.puts %w[id number crate_id created_at prerelease latest yanked].join("\t")
      CSV.foreach(path, headers: true, encoding: "UTF-8") do |row|
        crate_id = row.fetch("crate_id")
        next unless tracked_ids[crate_id]

        version = row.fetch("num")
        gzip.puts [
          row.fetch("id"),
          version,
          crate_id,
          row.fetch("created_at"),
          prerelease?(version),
          row.fetch("id") == default_versions[crate_id],
          parse_boolean(row.fetch("yanked"), "yanked")
        ].join("\t")
        count += 1
      end
    end
    count
  end

  def prerelease?(version)
    version.split("+", 2).first.include?("-")
  end

  def parse_boolean(value, field)
    normalized = value.to_s.downcase
    return true if TRUTHY.include?(normalized)
    return false if FALSEY.include?(normalized)

    raise ArgumentError, "#{field} must be a recognized boolean"
  end
end

if $PROGRAM_NAME == __FILE__
  dump_dir, seed_dir, archive_sha256, limit = ARGV
  unless dump_dir && seed_dir && archive_sha256
    abort "usage: build_cratesio_seed.rb <dump-dir> <seed-dir> <archive-sha256> [<limit>]"
  end

  result = CratesioSeedBuilder.build(dump_dir:, seed_dir:, archive_sha256:, limit: limit || 1_000)
  puts "tracked packages: #{result.fetch(:packages)}, tracked versions: #{result.fetch(:versions)}"
end
