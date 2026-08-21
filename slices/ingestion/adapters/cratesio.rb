# frozen_string_literal: true

require "cgi"
require "json"
require "time"
require "zlib"

module Ingestion
  module Adapters
    # crates.io adapter. Seed data comes from the daily public database dump,
    # distilled into seed/cratesio/ by research/build_cratesio_seed.rb; live
    # provenance comes from the v1 JSON API (see DATA_SOURCES.md). The dump is
    # daily, so re-seeding is also this registry's discovery path and
    # new_versions stays unimplemented.
    class Cratesio < RegistryAdapter
      include Deps["http_client"]

      API_BASE = "https://crates.io/api/v1"

      # crates.io stores trustpub_data on the version row, and the column was
      # added by the 2025-07-04-102806_add_trustpub_data_columns migration. It
      # records how a version was published, so it is never backfilled: a
      # version created before that date provably carries no trusted-publishing
      # metadata and needs no API call to establish it.
      PROVENANCE_AVAILABLE_SINCE = Time.utc(2025, 7, 4)

      # trustpub_data is tagged by provider and names its repository and run
      # fields per variant: GitHub carries repository/run_id, GitLab carries
      # project_path/job_id (crates_io_database/src/models/trustpub/data.rs).
      # Only sha is common. An unrecognized provider yields neither, so a new
      # variant records the publish without inventing an identity for it.
      TRUSTPUB_FIELDS = {
        "github" => %w[repository run_id].freeze,
        "gitlab" => %w[project_path job_id].freeze
      }.freeze

      def initialize(seed_dir: Hanami.app.root.join("seed", "cratesio").to_s, **deps)
        super(**deps)
        @seed_dir = seed_dir
      end

      def registry_slug = "cratesio"
      def display_name = "crates.io"
      def registry_url = "https://crates.io"

      def seed_as_of
        manifest = File.join(@seed_dir, "manifest.json")
        return nil unless File.exist?(manifest)

        Time.parse(JSON.parse(File.read(manifest)).fetch("dump_taken_at"))
      end

      # The dump exports no trustpub_data, so seeding observes package and
      # version state only. Seeded versions must stay unchecked rather than be
      # recorded as "no provenance found".
      def provenance_seed_as_of = nil

      def provenance_available_since = PROVENANCE_AVAILABLE_SINCE

      def each_tracked_package
        return enum_for(:each_tracked_package) unless block_given?

        each_tsv_row(File.join(@seed_dir, "top_1000.tsv")) do |rank, crate_id, name, downloads|
          yield({ name:, registry_ref: crate_id, rank: Integer(rank), downloads_total: Integer(downloads) })
        end
      end

      def each_seed_version
        return enum_for(:each_seed_version) unless block_given?

        each_gzip_tsv_row(File.join(@seed_dir, "tracked_versions.tsv.gz")) do |fields|
          id, number, crate_id, created_at, prerelease, latest, yanked = fields
          yield({
            registry_ref: id,
            package_ref: crate_id,
            number:,
            # crates.io releases carry no platform dimension; the column is
            # NOT NULL with an empty-string default across registries.
            platform: "",
            published_at: parse_utc(created_at),
            prerelease: prerelease == "true",
            latest: latest == "true",
            yanked: yanked == "true"
          })
        end
      end

      # Nothing to yield: the dump carries no provenance. Overridden rather
      # than inherited so seeding reaches the version upsert instead of
      # raising NotImplementedError.
      def each_seed_attestation
        enum_for(:each_seed_attestation) unless block_given?
      end

      # crates.io releases have no platform dimension; the keyword belongs to
      # the shared adapter contract used by RefreshProvenance.
      def fetch_provenance(name:, number:, platform:) # rubocop:disable Lint/UnusedMethodArgument
        response = http_client.get_json(
          "#{API_BASE}/crates/#{path_segment(name)}/#{path_segment(number)}", ttl: 0
        )
        trustpub = response&.dig("version", "trustpub_data")
        return nil unless trustpub.is_a?(Hash)

        provider = trustpub["provider"].to_s.strip.downcase
        return nil if provider.empty?

        repository_field, run_field = TRUSTPUB_FIELDS.fetch(provider, [])
        repository = repository_field && trustpub[repository_field]
        run_id = run_field && trustpub[run_field]

        {
          provenance_kind: "trustpub_metadata",
          provenance_provider: provider,
          source_repository: repository_url(provider, repository),
          workflow_ref: nil,
          commit_sha: trustpub["sha"],
          run_url: run_url(provider, repository, run_id),
          attestation_count: 1
        }
      end # rubocop:enable Lint/UnusedMethodArgument

      private

      def path_segment(value)
        CGI.escape(value).gsub("+", "%20")
      end

      # Read the header off the handle rather than Enumerable#drop, which
      # returns an Array and so would hold the whole decompressed seed in
      # memory before the first row reaches the chunked upsert.
      def each_tsv_row(path)
        File.open(path) do |file|
          file.gets
          file.each_line { |line| yield(line.chomp.split("\t", -1)) }
        end
      end

      def each_gzip_tsv_row(path)
        Zlib::GzipReader.open(path) do |gz|
          gz.gets
          gz.each_line { |line| yield(line.chomp.split("\t", -1)) }
        end
      end

      def parse_utc(value)
        Time.parse("#{value} UTC")
      end

      def repository_url(provider, repository)
        return unless repository
        return "https://github.com/#{repository}" if provider == "github"

        "https://gitlab.com/#{repository}" if provider == "gitlab"
      end

      def run_url(provider, repository, run_id)
        return unless repository && run_id
        return "https://github.com/#{repository}/actions/runs/#{run_id}" if provider == "github"

        "https://gitlab.com/#{repository}/-/jobs/#{run_id}" if provider == "gitlab"
      end
    end
  end
end
