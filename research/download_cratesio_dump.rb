# frozen_string_literal: true

# Download the crates.io daily database dump through the ingestion client's
# identifying User-Agent, throttling, and retry policy.
#
# Usage: bundle exec ruby research/download_cratesio_dump.rb <archive-path>

require "digest"
require "json"
require_relative "build_cratesio_seed"
require_relative "../slices/ingestion/http_client"

module CratesioDumpDownload
  module_function

  MAX_ARCHIVE_BYTES = 5_000_000_000

  def download(destination:, client:)
    result = client.download(
      CratesioSeedBuilder::SOURCE_URL,
      destination:,
      max_bytes: MAX_ARCHIVE_BYTES
    )
    bytes = result.fetch(:bytes)
    raise Ingestion::HTTPClient::Error, "crates.io dump is empty" unless bytes.positive?

    {
      source_url: CratesioSeedBuilder::SOURCE_URL,
      archive_sha256: Digest::SHA256.file(destination).hexdigest,
      bytes:
    }
  end
end

if $PROGRAM_NAME == __FILE__
  destination = ARGV.first
  abort "usage: download_cratesio_dump.rb <archive-path>" unless destination

  destination = File.expand_path(destination)
  client = Ingestion::HTTPClient.new(cache_dir: File.join(File.dirname(destination), ".http-cache"))

  puts JSON.generate(CratesioDumpDownload.download(destination:, client:))
end
