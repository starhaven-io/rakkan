# frozen_string_literal: true

# Second streaming pass over the dump: keep only the versions rows
# belonging to the tracked gem set, and only the columns the tracker needs.
# COPY escapes tabs/newlines inside values, so splitting raw lines on "\t"
# is safe.
#
# Usage: ruby research/filter_versions.rb <PostgreSQL.sql.gz> <top.tsv> <out.tsv>

sql_gz, top_tsv, out = ARGV

tracked = {}
File.foreach(top_tsv).drop(1).each { |l| tracked[l.split("\t")[1]] = true }

# versions columns (from the dump's COPY header):
# 0 id, 1 authors, 2 description, 3 number, 4 rubygem_id, 5 built_at,
# 6 updated_at, 7 summary, 8 platform, 9 created_at, 10 indexed,
# 11 prerelease, 12 position, 13 latest, 14 full_name, 15 licenses, 16 size,
# 17 requirements, 18 required_ruby_version, 19 sha256, 20 metadata,
# 21 required_rubygems_version, 22 yanked_at, 23 pusher_id,
# 24 canonical_number, 25 cert_chain, 26 pusher_api_key_id, 27 gem_platform,
# 28 gem_full_name, 29 spec_sha256, 30 info_checksum_v2, 31 yanked_info_checksum_v2
KEEP = [0, 3, 4, 8, 9, 10, 11, 13, 22, 23, 26].freeze
HEADER = %w[id number rubygem_id platform created_at indexed prerelease latest
            yanked_at pusher_id pusher_api_key_id].join("\t")

in_versions = false
kept = 0
total = 0
File.open(out, "w") do |f|
  f.puts HEADER
  IO.popen(["gzcat", sql_gz]) do |io|
    io.each_line do |line|
      if in_versions
        break if line.start_with?("\\.")

        total += 1
        fields = line.chomp.split("\t", -1)
        next unless tracked[fields[4]]

        f.puts fields.values_at(*KEEP).join("\t")
        kept += 1
      elsif line.start_with?("COPY public.versions ")
        in_versions = true
      end
    end
  end
end
puts "versions total=#{total} kept=#{kept}"
