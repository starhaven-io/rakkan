# frozen_string_literal: true

require "json"
require "time"
require "zlib"

module Ingestion
  module Adapters
    # RubyGems.org adapter. Seed data comes from the weekly public PostgreSQL
    # dump, distilled into seed/rubygems/ by research/build_seed.rb; live
    # freshness comes from the documented v1 JSON APIs (see DATA_SOURCES.md).
    class Rubygems < RegistryAdapter
      include Deps["http_client"]

      API_BASE = "https://rubygems.org/api/v1"

      def initialize(seed_dir: Hanami.app.root.join("seed", "rubygems").to_s, **deps)
        super(**deps)
        @seed_dir = seed_dir
      end

      def registry_slug = "rubygems"
      def display_name = "RubyGems.org"
      def registry_url = "https://rubygems.org"

      def seed_as_of
        manifest = File.join(@seed_dir, "manifest.json")
        return nil unless File.exist?(manifest)

        Time.parse(JSON.parse(File.read(manifest, encoding: "UTF-8")).fetch("dump_taken_at"))
      end

      # The RubyGems dump includes the complete attestations table at the same
      # cut time as its package and version data.
      def provenance_seed_as_of = seed_as_of

      def each_tracked_package
        return enum_for(:each_tracked_package) unless block_given?

        each_tsv_row(File.join(@seed_dir, "top_1000.tsv")) do |rank, rubygem_id, name, downloads|
          yield({ name:, registry_ref: rubygem_id, rank: Integer(rank), downloads_total: Integer(downloads) })
        end
      end

      def each_seed_version
        return enum_for(:each_seed_version) unless block_given?

        each_gzip_tsv_row(File.join(@seed_dir, "tracked_versions.tsv.gz")) do |fields|
          id, number, rubygem_id, platform, created_at, indexed, prerelease, latest, yanked_at, _pusher, _key = fields
          yield({
            registry_ref: id,
            package_ref: rubygem_id,
            number:,
            platform:,
            published_at: parse_utc(created_at),
            prerelease: prerelease == "t",
            latest: latest == "t",
            yanked: indexed != "t" || yanked_at != "\\N"
          })
        end
      end

      def each_seed_attestation
        return enum_for(:each_seed_attestation) unless block_given?

        # A version can carry several attestation rows; group before parsing
        # so attestation_count is right.
        by_version = Hash.new { |h, k| h[k] = [] }
        each_gzip_tsv_row(File.join(@seed_dir, "tracked_attestations.tsv.gz")) do |fields|
          _id, version_id, body, _media_type, _created, _updated = fields
          by_version[version_id] << JSON.parse(unescape_copy(body))
        end

        by_version.each do |version_ref, bundles|
          provenance = Rubygems::Attestation.parse(bundles)
          yield({ version_ref:, provenance: }) if provenance
        end
      end

      def fetch_provenance(name:, number:, platform:)
        full_name = platform == "ruby" ? "#{name}-#{number}" : "#{name}-#{number}-#{platform}"
        # ttl: 0 bypasses the read cache: a provenance check exists to observe
        # current registry state, and a cached empty answer would stay empty
        # forever. The response is still written to the cache for the record.
        bundles = http_client.get_json("#{API_BASE}/attestations/#{full_name}.json", ttl: 0)
        return nil if bundles.nil? || bundles.empty?

        Rubygems::Attestation.parse(bundles)
      end

      # timeframe_versions pages ascending by created_at (verified live:
      # pages are disjoint, oldest first). drained: false signals
      # the page budget ran out while pages were still full.
      def new_versions(from:, to:, max_pages:)
        entries = []
        drained = true
        pages = 0
        (1..max_pages).each do |page|
          url = "#{API_BASE}/timeframe_versions.json?from=#{from.utc.iso8601}&to=#{to.utc.iso8601}&page=#{page}"
          batch = http_client.get_json(url, ttl: 3600)
          pages = page
          break if batch.nil? || batch.empty?

          batch.each do |entry|
            entries << {
              package_name: entry.fetch("name"),
              number: entry.fetch("number"),
              platform: entry.fetch("platform"),
              published_at: Time.parse(entry.fetch("created_at")),
              prerelease: entry.fetch("prerelease"),
              yanked: entry.fetch("yanked", false)
            }
          end

          if page == max_pages
            drained = false
            break
          end
        end
        { entries:, drained:, pages: }
      end

      # Postgres COPY escapes backslash, tab, newline, and carriage return
      # inside values; reverse that before JSON parsing.
      COPY_ESCAPES = { "\\\\" => "\\", "\\t" => "\t", "\\n" => "\n", "\\r" => "\r" }.freeze

      private

      # Read the header off the handle rather than Enumerable#drop, which
      # returns an Array and so would hold the whole decompressed seed in
      # memory before the first row reaches the chunked upsert. Seed files are
      # UTF-8 because their dumps are; say so rather than inherit whatever
      # locale the process happens to run under.
      def each_tsv_row(path)
        File.open(path, encoding: "UTF-8") do |file|
          file.gets
          file.each_line { |line| yield(line.chomp.split("\t", -1)) }
        end
      end

      def each_gzip_tsv_row(path)
        Zlib::GzipReader.open(path, external_encoding: "UTF-8") do |gz|
          gz.gets
          gz.each_line { |line| yield(line.chomp.split("\t", -1)) }
        end
      end

      def unescape_copy(value)
        value.gsub(/\\[\\tnr]/, COPY_ESCAPES)
      end

      def parse_utc(value)
        Time.parse("#{value} UTC")
      end
    end
  end
end
