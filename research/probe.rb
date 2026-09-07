# frozen_string_literal: true

# Fetch sample responses from registry APIs and save them
# verbatim under research/samples/. Polite client: identifying User-Agent,
# ~4 req/s max (rubygems.org documents 10 req/s), stops on repeated errors.
#
# Usage: ruby research/probe.rb <url> <output-path> [<url> <output-path> ...]

require "fileutils"
require "uri"
require_relative "../slices/ingestion/http_client"

ALLOWED_PROBE_HOSTS = %w[api.deps.dev crates.io pypi.org rubygems.org].freeze
abort "usage: ruby research/probe.rb <url> <output-path> [<url> <output-path> ...]" if ARGV.empty? || ARGV.length.odd?

cache_dir = File.expand_path("../var/cache/http", __dir__)
client = Ingestion::HTTPClient.new(cache_dir:)

ARGV.each_slice(2) do |url, out|
  uri = URI(url)
  abort "unsupported probe host: #{uri.host}" unless uri.is_a?(URI::HTTPS) && ALLOWED_PROBE_HOSTS.include?(uri.host)
  FileUtils.mkdir_p(File.dirname(out))
  result = client.download(
    url,
    destination: out,
    accept: "application/json",
    max_bytes: Ingestion::HTTPClient::MAX_JSON_BYTES
  )
  puts "200 #{url} -> #{out} (#{result.fetch(:bytes)} bytes)"
end
