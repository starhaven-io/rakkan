# frozen_string_literal: true

# Fetch sample responses from registry APIs and save them
# verbatim under research/samples/. Polite client: identifying User-Agent,
# ~4 req/s max (rubygems.org documents 10 req/s), stops on repeated errors.
#
# Usage: ruby research/probe.rb <url> <output-path> [<url> <output-path> ...]

require "net/http"
require "uri"
require "fileutils"

USER_AGENT = "rakkan/0.1 (trusted publishing adoption tracker; +https://rakkan.dev)"

ARGV.each_slice(2) do |url, out|
  abort "need url/output pairs" if out.nil?
  uri = URI(url)
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
    http.get(uri.request_uri, { "User-Agent" => USER_AGENT, "Accept" => "application/json" })
  end
  FileUtils.mkdir_p(File.dirname(out))
  File.write(out, res.body)
  puts "#{res.code} #{url} -> #{out} (#{res.body.bytesize} bytes)"
  sleep 0.25
end
