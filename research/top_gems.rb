# frozen_string_literal: true

# Compute the top-N gems by total downloads from the extracted
# gem_downloads + rubygems dump tables. gem_downloads carries per-version rows
# plus a version_id=0 row per gem holding the gem's total download count
# (verified below before relying on it).
#
# Usage: ruby research/top_gems.rb <extracted-dir> <N> <out.tsv>

dir, n, out = ARGV
n = Integer(n)

# rubygems.tsv: id, name, created_at, updated_at, indexed, organization_id
names = {}
indexed = {}
File.foreach(File.join(dir, "rubygems.tsv")) do |line|
  f = line.chomp.split("\t")
  names[f[0]] = f[1]
  indexed[f[0]] = f[4]
end

# gem_downloads.tsv: id, rubygem_id, version_id, count
totals = {}
per_version_sum = Hash.new(0)
File.foreach(File.join(dir, "gem_downloads.tsv")) do |line|
  f = line.chomp.split("\t")
  rubygem_id = f[1]
  version_id = f[2]
  count = f[3].to_i
  if version_id == "0"
    totals[rubygem_id] = count
  else
    per_version_sum[rubygem_id] += count
  end
end

# Sanity check the version_id=0 semantics on a well-known gem before trusting it
rack_id = names.key("rack")
puts "sanity rack: total=#{totals[rack_id]} sum(per-version)=#{per_version_sum[rack_id]}"

top = totals.reject { |id, _| id == "0" || names[id].nil? || indexed[id] != "t" }
            .sort_by { |_, c| -c }
            .first(n)

File.open(out, "w") do |f|
  f.puts "rank\trubygem_id\tname\tdownloads"
  top.each_with_index { |(id, c), i| f.puts "#{i + 1}\t#{id}\t#{names[id]}\t#{c}" }
end
puts "wrote #{top.size} rows to #{out}"
puts "top 10: #{top.first(10).map { |id, c| "#{names[id]} (#{c})" }.join(", ")}"
