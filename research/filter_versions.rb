# frozen_string_literal: true

require "csv"
require "fileutils"
require "tempfile"
require "zlib"

module RubygemsVersionFilter
  module_function

  REQUIRED_COLUMNS = %w[
    id number rubygem_id platform created_at indexed prerelease latest
    yanked_at pusher_id pusher_api_key_id
  ].freeze
  COPY_HEADER = /\ACOPY public\.versions \(([^)]+)\) FROM stdin;\s*\z/

  def filter(sql_gz:, tracked_packages_path:, output_path:)
    tracked = tracked_package_ids(tracked_packages_path)
    found = false
    complete = false
    columns = nil
    indexes = nil
    total = 0
    kept = 0
    version_ids = {}
    package_ids_with_versions = {}

    FileUtils.mkdir_p(File.dirname(File.expand_path(output_path)))
    Tempfile.create([".#{File.basename(output_path)}-", ".tmp"],
                    File.dirname(File.expand_path(output_path))) do |output|
      output.set_encoding("UTF-8")
      output.puts REQUIRED_COLUMNS.join("\t")
      Zlib::GzipReader.open(sql_gz, external_encoding: "UTF-8") do |gzip|
        gzip.each_line do |line|
          unless found
            match = COPY_HEADER.match(line)
            next unless match

            columns = match[1].split(", ").map { |column| column.delete_prefix('"').delete_suffix('"') }
            missing = REQUIRED_COLUMNS - columns
            raise ArgumentError, "versions COPY is missing columns: #{missing.join(", ")}" unless missing.empty?

            indexes = REQUIRED_COLUMNS.map { |column| columns.index(column) }
            found = true
            next
          end

          if line.chomp == "\\."
            complete = true
            break
          end

          fields = line.chomp.split("\t", -1)
          unless fields.length == columns.length
            raise ArgumentError,
                  "versions row width does not match its COPY schema"
          end

          total += 1
          package_id = fields.fetch(columns.index("rubygem_id"))
          next unless tracked.key?(package_id)

          selected = indexes.map { |index| fields.fetch(index) }
          version_id = selected.first
          raise ArgumentError, "duplicate version id #{version_id}" if version_ids[version_id]

          version_ids[version_id] = true
          package_ids_with_versions[package_id] = true
          output.puts selected.join("\t")
          kept += 1
        end
      end

      raise ArgumentError, "versions COPY block was not found" unless found
      raise ArgumentError, "versions COPY block was not terminated" unless complete

      missing_packages = tracked.keys - package_ids_with_versions.keys
      unless missing_packages.empty?
        raise ArgumentError, "#{missing_packages.length} tracked packages have no version rows"
      end

      output.flush
      output.fsync
      File.rename(output.path, output_path)
    end
    { total:, kept: }
  end

  def tracked_package_ids(path)
    rows = CSV.read(path, headers: true, col_sep: "\t", encoding: "UTF-8")
    raise ArgumentError, "unexpected tracked-package header" unless rows.headers == %w[rank rubygem_id name downloads]

    rows.each_with_object({}) do |row, ids|
      id = row.fetch("rubygem_id")
      raise ArgumentError, "duplicate tracked package id #{id}" if ids[id]

      ids[id] = true
    end
  end
end

if $PROGRAM_NAME == __FILE__
  sql_gz, tracked_packages_path, output_path = ARGV
  unless sql_gz && tracked_packages_path && output_path
    abort "usage: filter_versions.rb <PostgreSQL.sql.gz> <top.tsv> <out.tsv>"
  end

  result = RubygemsVersionFilter.filter(sql_gz:, tracked_packages_path:, output_path:)
  puts "versions total=#{result.fetch(:total)} kept=#{result.fetch(:kept)}"
end
