# frozen_string_literal: true

require "fileutils"
require "tempfile"

module RubygemsTopPackages
  module_function

  def build(extracted_dir:, limit:, output_path:)
    limit = Integer(limit)
    raise ArgumentError, "limit must be positive" unless limit.positive?

    names = {}
    indexed = {}
    each_table_row(extracted_dir, "rubygems", %w[id name indexed]) do |row|
      id = row.fetch("id")
      name = row.fetch("name")
      raise ArgumentError, "duplicate RubyGems package id #{id}" if names.key?(id)
      raise ArgumentError, "package name must not be empty" if name.empty?

      names[id] = name
      indexed[id] = row.fetch("indexed")
    end

    totals = {}
    per_version_sum = Hash.new(0)
    each_table_row(extracted_dir, "gem_downloads", %w[rubygem_id version_id count]) do |row|
      package_id = row.fetch("rubygem_id")
      count = Integer(row.fetch("count"), 10)
      raise ArgumentError, "download counts must be non-negative" if count.negative?

      if row.fetch("version_id") == "0"
        raise ArgumentError, "duplicate total download row for #{package_id}" if totals.key?(package_id)

        totals[package_id] = count
      else
        per_version_sum[package_id] += count
      end
    end

    rack_id = names.key("rack")
    unless rack_id && totals[rack_id]&.positive? && per_version_sum[rack_id].positive? &&
           totals.fetch(rack_id) >= per_version_sum.fetch(rack_id)
      raise ArgumentError, "rack download totals do not match the expected dump semantics"
    end

    tracked = totals.filter_map do |id, downloads|
      name = names[id]
      [id, name, downloads] if id != "0" && name && indexed[id] == "t"
    end
    tracked.sort_by! { |id, name, downloads| [-downloads, name, id] }
    tracked = tracked.first(limit)
    unless tracked.length == limit
      raise ArgumentError,
            "dump contains only #{tracked.length} eligible packages; expected #{limit}"
    end

    write_atomic(output_path) do |file|
      file.puts "rank\trubygem_id\tname\tdownloads"
      tracked.each_with_index do |(id, name, downloads), index|
        file.puts [index + 1, id, name, downloads].join("\t")
      end
    end
    { packages: tracked.length }
  end

  def each_table_row(extracted_dir, table, required_columns)
    columns = File.read(File.join(extracted_dir, "#{table}.columns"), encoding: "UTF-8").chomp.split("\t", -1)
    missing = required_columns - columns
    raise ArgumentError, "#{table} is missing columns: #{missing.join(", ")}" unless missing.empty?

    File.foreach(File.join(extracted_dir, "#{table}.tsv"), encoding: "UTF-8") do |line|
      fields = line.chomp.split("\t", -1)
      raise ArgumentError, "#{table} row width does not match its COPY schema" unless fields.length == columns.length

      yield columns.zip(fields).to_h
    end
  end

  def write_atomic(path)
    FileUtils.mkdir_p(File.dirname(File.expand_path(path)))
    Tempfile.create([".#{File.basename(path)}-", ".tmp"], File.dirname(File.expand_path(path))) do |file|
      file.set_encoding("UTF-8")
      yield file
      file.flush
      file.fsync
      File.rename(file.path, path)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  extracted_dir, limit, output_path = ARGV
  abort "usage: top_gems.rb <extracted-dir> <limit> <out.tsv>" unless extracted_dir && limit && output_path

  result = RubygemsTopPackages.build(extracted_dir:, limit:, output_path:)
  puts "wrote #{result.fetch(:packages)} rows to #{output_path}"
end
