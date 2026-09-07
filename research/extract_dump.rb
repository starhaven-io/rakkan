# frozen_string_literal: true

# Stream selected COPY tables from the RubyGems weekly PostgreSQL dump without
# requiring PostgreSQL or platform-specific gzip commands.

require "fileutils"
require "tmpdir"
require "zlib"

module RubygemsDumpExtractor
  module_function

  COPY_HEADER = /\ACOPY public\.([a-z_]+) \(([^)]+)\) FROM stdin;\s*\z/
  TABLE_NAME = /\A[a-z_]+\z/

  def extract(sql_gz:, output_dir:, tables:)
    tables = Array(tables).uniq
    raise ArgumentError, "at least one table is required" if tables.empty?
    raise ArgumentError, "invalid table name" unless tables.all? { |table| table.match?(TABLE_NAME) }

    FileUtils.mkdir_p(output_dir)
    parent = File.dirname(File.expand_path(output_dir))
    counts = Hash.new(0)
    seen = {}
    current = nil
    output = nil
    column_count = nil

    Dir.mktmpdir(".rubygems-extract-", parent) do |temporary|
      Zlib::GzipReader.open(sql_gz, external_encoding: "UTF-8") do |gzip|
        gzip.each_line do |line|
          if current
            if line.chomp == "\\."
              output.close
              output = nil
              current = nil
              column_count = nil
            else
              fields = line.chomp.split("\t", -1)
              unless fields.length == column_count
                raise ArgumentError, "#{current} row has #{fields.length} fields; expected #{column_count}"
              end

              output.write(line)
              counts[current] += 1
            end
            next
          end

          match = COPY_HEADER.match(line)
          next unless match

          table = match[1]
          next unless tables.include?(table)
          raise ArgumentError, "duplicate COPY block for #{table}" if seen[table]

          columns = match[2].split(", ").map { |column| column.delete_prefix('"').delete_suffix('"') }
          raise ArgumentError, "empty COPY schema for #{table}" if columns.empty? || columns.any?(&:empty?)

          seen[table] = true
          current = table
          column_count = columns.length
          output = File.new(File.join(temporary, "#{table}.tsv"), "w", encoding: "UTF-8")
          File.write(File.join(temporary, "#{table}.columns"), "#{columns.join("\t")}\n", encoding: "UTF-8")
        end
      end

      raise ArgumentError, "unterminated COPY block for #{current}" if current

      missing = tables.reject { |table| seen[table] && counts[table].positive? }
      raise ArgumentError, "missing or empty COPY tables: #{missing.join(", ")}" unless missing.empty?

      tables.each do |table|
        %w[tsv columns].each do |extension|
          FileUtils.mv(File.join(temporary, "#{table}.#{extension}"), File.join(output_dir, "#{table}.#{extension}"))
        end
      end
    ensure
      output&.close
    end

    counts.to_h
  end
end

if $PROGRAM_NAME == __FILE__
  sql_gz, output_dir, *tables = ARGV
  abort "usage: extract_dump.rb <sql.gz> <output-dir> <tables...>" unless sql_gz && output_dir && !tables.empty?

  RubygemsDumpExtractor.extract(sql_gz:, output_dir:, tables:).each do |table, count|
    puts "#{table}: #{count} rows"
  end
end
