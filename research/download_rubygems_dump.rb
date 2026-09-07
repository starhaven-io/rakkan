# frozen_string_literal: true

require "date"
require "digest"
require "json"
require "rexml/document"
require "rexml/xpath"
require "tmpdir"
require "uri"
require_relative "build_seed"
require_relative "../slices/ingestion/http_client"

module RubygemsDumpDownload
  module_function

  MAX_ARCHIVE_BYTES = 2_000_000_000
  MAX_LISTING_BYTES = 5 * 1024 * 1024
  MAX_CLOCK_SKEW = 5 * 60
  KEY_PATTERN = RubygemsSeedBuilder::DUMP_KEY

  def download(destination:, client:, now: Time.now.utc)
    entries = listing_urls(now).flat_map do |url|
      Dir.mktmpdir("rakkan-rubygems-listing") do |directory|
        path = File.join(directory, "listing.xml")
        client.download(url, destination: path, accept: "application/xml", max_bytes: MAX_LISTING_BYTES)
        parse_listing(File.read(path, encoding: "UTF-8"))
      end
    end
    candidates = entries.select do |candidate|
      match = KEY_PATTERN.match(candidate.fetch(:key))
      match && Time.utc(*match.captures.map { |value| Integer(value, 10) }) <= now + MAX_CLOCK_SKEW
    end
    entry = candidates.max_by { |candidate| candidate.fetch(:key) }
    raise ArgumentError, "RubyGems dump listing contained no current archive" unless entry
    unless entry.fetch(:size).positive? && entry.fetch(:size) <= MAX_ARCHIVE_BYTES
      raise ArgumentError, "RubyGems dump archive size is outside the accepted range"
    end

    source_url = "#{RubygemsSeedBuilder::SOURCE_BASE}/#{entry.fetch(:key)}"
    result = client.download(source_url, destination:, max_bytes: entry.fetch(:size))
    unless result.fetch(:bytes) == entry.fetch(:size)
      raise Ingestion::HTTPClient::Error, "RubyGems dump size does not match its bucket listing"
    end

    {
      source_url:,
      dump_key: entry.fetch(:key),
      bytes: result.fetch(:bytes),
      archive_sha256: Digest::SHA256.file(destination).hexdigest
    }
  end

  def listing_urls(now)
    current = Date.new(now.year, now.month, 1)
    previous = current << 1
    [previous, current].map do |month|
      prefix = format("production/public_postgresql/%<year>04d.%<month>02d", year: month.year, month: month.month)
      query = URI.encode_www_form("list-type" => "2", "prefix" => prefix, "max-keys" => "1000")
      "#{RubygemsSeedBuilder::SOURCE_BASE}/?#{query}"
    end
  end

  def parse_listing(xml)
    document = REXML::Document.new(xml)
    namespace = document.root&.namespace
    raise ArgumentError, "RubyGems dump listing has no namespace" if namespace.to_s.empty?

    namespaces = { "s3" => namespace }
    truncated = REXML::XPath.first(document, "//s3:IsTruncated", namespaces)&.text
    raise ArgumentError, "RubyGems dump listing was incomplete" unless truncated == "false"

    REXML::XPath.match(document, "//s3:Contents", namespaces).filter_map do |content|
      key = REXML::XPath.first(content, "s3:Key", namespaces)&.text
      size = REXML::XPath.first(content, "s3:Size", namespaces)&.text
      storage = REXML::XPath.first(content, "s3:StorageClass", namespaces)&.text
      next unless key && size&.match?(/\A\d+\z/) && storage == "STANDARD"

      { key:, size: Integer(size, 10) }
    end
  rescue REXML::ParseException => e
    raise ArgumentError, "invalid RubyGems dump listing: #{e.message}", cause: e
  end
end

if $PROGRAM_NAME == __FILE__
  destination = ARGV.first
  abort "usage: download_rubygems_dump.rb <archive-path>" unless destination

  destination = File.expand_path(destination)
  client = Ingestion::HTTPClient.new(cache_dir: File.join(File.dirname(destination), ".http-cache"))
  puts JSON.generate(RubygemsDumpDownload.download(destination:, client:))
end
