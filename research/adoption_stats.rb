# frozen_string_literal: true

# Join extracted attestations against tracked (top-1000) versions to
# get the first honest read on adoption, and to test the hypothesis that
# trusted-publisher pushes have pusher_id NULL + pusher_api_key_id set.
#
# Usage: ruby research/adoption_stats.rb <extracted-dir>

dir = ARGV.fetch(0)

attested = {} # version_id => media_type
File.foreach(File.join(dir, "attestations.tsv")) do |line|
  f = line.chomp.split("\t")
  attested[f[1]] = f[3]
end
puts "total attestations in registry: #{attested.size}"

names = File.foreach(File.join(dir, "top_1000.tsv")).drop(1)
            .to_h do |l|
  f = l.chomp.split("\t")
  [f[1], f[2]]
end

gems_attested = Hash.new { |h, k| h[k] = [] }
pusher_shapes = Hash.new(0)
attested_rows = 0
total_rows = 0
newest_attested = []

File.foreach(File.join(dir, "tracked_versions.tsv")).drop(1).each do |line|
  id, number, rubygem_id, _platform, created_at, indexed, _pre, _latest,
    _yanked, pusher_id, pusher_api_key_id = line.chomp.split("\t", -1)
  next unless indexed == "t"

  total_rows += 1
  next unless attested.key?(id)

  attested_rows += 1
  gems_attested[rubygem_id] << number
  newest_attested << [created_at, names[rubygem_id], number]
  shape = "pusher_id=#{pusher_id == '\\N' ? "NULL" : "set"} api_key=#{pusher_api_key_id == '\\N' ? "NULL" : "set"}"
  pusher_shapes[shape] += 1
end

puts "tracked (top-1000) indexed versions: #{total_rows}"
puts "tracked versions with attestation: #{attested_rows}"
puts "top-1000 gems with >=1 attested version: #{gems_attested.size} (#{(gems_attested.size / 10.0).round(1)}%)"
puts "\npusher field shapes on attested tracked versions:"
pusher_shapes.each { |k, v| puts "  #{k}: #{v}" }
puts "\n15 most recently created attested tracked versions:"
newest_attested.sort.reverse.first(15).each { |c, n, v| puts "  #{c}  #{n} #{v}" }
puts "\nsample attested gems: #{gems_attested.keys.first(25).map { |id| names[id] }.join(", ")}"
