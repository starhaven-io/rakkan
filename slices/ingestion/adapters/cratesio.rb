# frozen_string_literal: true

require "cgi"

module Ingestion
  module Adapters
    # Provenance-side crates.io adapter. Bulk tracked-set seeding and release
    # discovery remain gated on the daily dump investigation.
    class Cratesio < RegistryAdapter
      include Deps["http_client"]

      API_BASE = "https://crates.io/api/v1"

      def registry_slug = "cratesio"
      def display_name = "crates.io"
      def registry_url = "https://crates.io"

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

        repository = trustpub["repository"]
        run_id = trustpub["run_id"]

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

      def repository_url(provider, repository)
        return unless repository
        return "https://github.com/#{repository}" if provider == "github"

        repository
      end

      def run_url(provider, repository, run_id)
        return unless provider == "github" && repository && run_id

        "https://github.com/#{repository}/actions/runs/#{run_id}"
      end
    end
  end
end
