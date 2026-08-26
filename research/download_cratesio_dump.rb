# frozen_string_literal: true

# Download the crates.io daily database dump through the ingestion client's
# identifying User-Agent, throttling, and retry policy.
#
# Usage: bundle exec ruby research/download_cratesio_dump.rb <archive-path>

require "json"
require_relative "build_cratesio_seed"
require_relative "../slices/ingestion/http_client"

destination = ARGV.first
abort "usage: download_cratesio_dump.rb <archive-path>" unless destination

destination = File.expand_path(destination)
client = Ingestion::HTTPClient.new(cache_dir: File.join(File.dirname(destination), ".http-cache"))
result = client.download(CratesioSeedBuilder::SOURCE_URL, destination:)

puts JSON.generate({ source_url: CratesioSeedBuilder::SOURCE_URL, bytes: result.fetch(:bytes) })
