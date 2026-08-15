# frozen_string_literal: true

# Distill the dump extracts into compact seed files that
# get committed with the repo, so ingestion and tests run on real data without
# re-downloading the 650 MB dump.
#
#   seed/rubygems/top_1000.tsv            rank, rubygem_id, name, downloads
#   seed/rubygems/tracked_versions.tsv.gz version rows for tracked gems
#   seed/rubygems/tracked_attestations.tsv.gz attestation rows for tracked versions
#
# Usage: ruby research/build_seed.rb <extracted-dir> <seed-dir> [<dump-key>]
#
# When <dump-key> (the S3 object key of the source dump) is given, a
# manifest.json is written so ingestion can date the seed data.

require "fileutils"
require "json"
require "zlib"

dir, seed, dump_key = ARGV
FileUtils.mkdir_p(seed)

if dump_key
  taken_at = dump_key[%r{/(\d{4})\.(\d{2})\.(\d{2})\.(\d{2})\.(\d{2})\.(\d{2})/}]
             .then { Time.utc(*Regexp.last_match.captures.map(&:to_i)) }
  manifest = {
    source: "rubygems.org weekly public PostgreSQL dump",
    dump_key: dump_key,
    dump_taken_at: taken_at.iso8601,
    built_by: "research/build_seed.rb",
    tracked_set: "top 1000 gems by total downloads (gem_downloads version_id=0 rows)"
  }
  File.write(File.join(seed, "manifest.json"), JSON.pretty_generate(manifest))
end

FileUtils.cp(File.join(dir, "top_1000.tsv"), File.join(seed, "top_1000.tsv"))

tracked_version_ids = {}
Zlib::GzipWriter.open(File.join(seed, "tracked_versions.tsv.gz")) do |gz|
  File.foreach(File.join(dir, "tracked_versions.tsv")).each_with_index do |line, i|
    tracked_version_ids[line.split("\t", 2)[0]] = true unless i.zero?
    gz.write(line)
  end
end

kept = 0
Zlib::GzipWriter.open(File.join(seed, "tracked_attestations.tsv.gz")) do |gz|
  gz.puts %w[id version_id body media_type created_at updated_at].join("\t")
  File.foreach(File.join(dir, "attestations.tsv")) do |line|
    next unless tracked_version_ids[line.split("\t", 3)[1]]

    gz.write(line)
    kept += 1
  end
end

puts "tracked versions: #{tracked_version_ids.size}, tracked attestations kept: #{kept}"
