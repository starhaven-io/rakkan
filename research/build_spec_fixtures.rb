# frozen_string_literal: true

# Distill the committed seed data (itself dump-derived) into a miniature
# fixture set for the spec suite, plus copies of the recorded API sample
# responses. Keeps specs on real recorded data with no live calls.
#
# Usage: ruby research/build_spec_fixtures.rb

require "fileutils"
require "zlib"

ROOT = File.expand_path("..", __dir__)
SEED = File.join(ROOT, "seed", "rubygems")
FIXTURES = File.join(ROOT, "spec", "fixtures")

GEMS = %w[psych rack logger].freeze
VERSIONS_PER_GEM = 6

FileUtils.mkdir_p(File.join(FIXTURES, "seed", "rubygems"))
FileUtils.mkdir_p(File.join(FIXTURES, "api"))

# --- top TSV: keep chosen gems, preserving real ranks/downloads -------------
top_rows = File.readlines(File.join(SEED, "top_1000.tsv"))
header, *rows = top_rows
kept_top = rows.select { |l| GEMS.include?(l.split("\t")[2]) }
File.write(File.join(FIXTURES, "seed", "rubygems", "top_1000.tsv"), header + kept_top.join)
gem_ids = kept_top.to_h do |l|
  f = l.split("\t")
  [f[1], f[2]]
end
puts "gems kept: #{gem_ids.values.join(", ")}"

# --- versions: newest N per gem --------------------------------------------
lines = Zlib::GzipReader.open(File.join(SEED, "tracked_versions.tsv.gz"), &:readlines)
vheader, *vrows = lines
by_gem = vrows.group_by { |l| l.split("\t")[2] }.slice(*gem_ids.keys)
kept_versions = by_gem.values.flat_map do |rs|
  rs.sort_by { |l| l.split("\t")[4] }.last(VERSIONS_PER_GEM)
end
Zlib::GzipWriter.open(File.join(FIXTURES, "seed", "rubygems", "tracked_versions.tsv.gz")) do |gz|
  gz.write(vheader)
  kept_versions.each { |l| gz.write(l) }
end
kept_version_ids = kept_versions.to_h { |l| [l.split("\t")[0], true] }
puts "versions kept: #{kept_versions.size}"

# --- attestations for kept versions ----------------------------------------
alines = Zlib::GzipReader.open(File.join(SEED, "tracked_attestations.tsv.gz"), &:readlines)
aheader, *arows = alines
kept_atts = arows.select { |l| kept_version_ids[l.split("\t")[1]] }
Zlib::GzipWriter.open(File.join(FIXTURES, "seed", "rubygems", "tracked_attestations.tsv.gz")) do |gz|
  gz.write(aheader)
  kept_atts.each { |l| gz.write(l) }
end
puts "attestations kept: #{kept_atts.size}"

FileUtils.cp(File.join(SEED, "manifest.json"), File.join(FIXTURES, "seed", "rubygems", "manifest.json"))

# --- API samples ------------------------------------------------------------
%w[
  v1_attestations_sigstore-0.2.3.json
  v1_attestations_rack-3.2.7.json
  v1_timeframe_versions_sample.json
].each do |name|
  FileUtils.cp(File.join(ROOT, "research", "samples", "rubygems", name), File.join(FIXTURES, "api", name))
end
puts "api samples copied"
