# frozen_string_literal: true

# Distill an extracted crates.io daily database dump into deterministic seed
# inputs. The dump provides package/version state but no trusted-publishing
# metadata, so this builder deliberately emits no provenance observations.
#
# Usage: ruby research/build_cratesio_seed.rb <dump-dir> <seed-dir> [<limit>]
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

  def build(dump_dir:, seed_dir:, limit: 1_000)
    limit = Integer(limit)
    raise ArgumentError, "limit must be positive" unless limit.positive?

    data_dir = File.join(dump_dir, "data")
    metadata = JSON.parse(File.read(File.join(dump_dir, "metadata.json"), encoding: "UTF-8"))
    downloads = downloads_by_crate(File.join(data_dir, "crate_downloads.csv"))
    tracked = top_crates(File.join(data_dir, "crates.csv"), downloads, limit)
    tracked_ids = tracked.to_h { |crate| [crate.fetch("id"), true] }
    default_versions = default_versions_by_crate(
      File.join(data_dir, "default_versions.csv"), tracked_ids
    )

    FileUtils.mkdir_p(seed_dir)
    write_manifest(seed_dir, metadata, limit)
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
    CSV.foreach(path, headers: true, encoding: "UTF-8").to_h do |row|
      [row.fetch("crate_id"), Integer(row.fetch("downloads"))]
    end
  end

  def top_crates(path, downloads, limit)
    crates = CSV.foreach(path, headers: true, encoding: "UTF-8").filter_map do |row|
      crate_downloads = downloads[row.fetch("id")]
      next unless crate_downloads

      { "id" => row.fetch("id"), "name" => row.fetch("name"), "downloads" => crate_downloads }
    end
    crates.sort_by { |crate| [-crate.fetch("downloads"), crate.fetch("name")] }.first(limit)
  end

  def default_versions_by_crate(path, tracked_ids)
    CSV.foreach(path, headers: true, encoding: "UTF-8").filter_map do |row|
      crate_id = row.fetch("crate_id")
      [crate_id, row.fetch("version_id")] if tracked_ids[crate_id]
    end.to_h
  end

  def write_manifest(seed_dir, metadata, limit)
    manifest = {
      source: "crates.io daily database dump",
      source_url: SOURCE_URL,
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
          truthy?(row.fetch("yanked"))
        ].join("\t")
        count += 1
      end
    end
    count
  end

  def prerelease?(version)
    version.split("+", 2).first.include?("-")
  end

  def truthy?(value)
    TRUTHY.include?(value.downcase)
  end
end

if $PROGRAM_NAME == __FILE__
  dump_dir, seed_dir, limit = ARGV
  abort "usage: build_cratesio_seed.rb <dump-dir> <seed-dir> [<limit>]" unless dump_dir && seed_dir

  result = CratesioSeedBuilder.build(dump_dir:, seed_dir:, limit: limit || 1_000)
  puts "tracked packages: #{result.fetch(:packages)}, tracked versions: #{result.fetch(:versions)}"
end
