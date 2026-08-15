# frozen_string_literal: true

# Stream-extract selected tables from the RubyGems weekly PostgreSQL
# dump (plain SQL format) without needing a Postgres install. COPY blocks are
# tab-separated text terminated by "\.", so a line-oriented state machine is
# enough.
#
# Usage: ruby research/extract_dump.rb <PostgreSQL.sql.gz> <output-dir> table1 table2 ...

sql_gz, out_dir, *tables = ARGV
abort "usage: extract_dump.rb <sql.gz> <out-dir> <tables...>" if tables.empty?

require "fileutils"
FileUtils.mkdir_p(out_dir)

wanted = tables.to_h { |t| [t, nil] }
current = nil
counts = Hash.new(0)

IO.popen(["gzcat", sql_gz]) do |io|
  io.each_line do |line|
    if current
      if line.start_with?("\\.")
        wanted[current].close
        current = nil
      else
        wanted[current].write(line)
        counts[current] += 1
      end
    elsif line.start_with?("COPY public.")
      table = line[/\ACOPY public\.(\w+)/, 1]
      next unless wanted.key?(table)

      current = table
      wanted[table] = File.open(File.join(out_dir, "#{table}.tsv"), "w")
      File.write(File.join(out_dir, "#{table}.columns"), line[/\((.+)\)/, 1])
    end
  end
end

counts.each { |t, n| puts "#{t}: #{n} rows" }
