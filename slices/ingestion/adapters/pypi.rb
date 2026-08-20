# frozen_string_literal: true

require "cgi"

module Ingestion
  module Adapters
    # Provenance-side PyPI adapter. PyPI exposes PEP 740 provenance per file,
    # so a release observation must aggregate every distribution it contains.
    class Pypi < RegistryAdapter
      include Deps["http_client"]

      API_BASE = "https://pypi.org"
      INTEGRITY_ACCEPT = "application/vnd.pypi.integrity.v1+json"

      def registry_slug = "pypi"
      def display_name = "PyPI"
      def registry_url = "https://pypi.org"

      # PyPI provenance is aggregated to a release; the platform keyword
      # belongs to the shared adapter contract used by RefreshProvenance.
      def fetch_provenance(name:, number:, platform:) # rubocop:disable Lint/UnusedMethodArgument
        project = path_segment(name)
        version = path_segment(number)
        release = http_client.get_json("#{API_BASE}/pypi/#{project}/#{version}/json", ttl: 3600)
        return nil unless release

        provenance_objects = release.fetch("urls", []).filter_map do |file|
          filename = file["filename"] or next
          url = "#{API_BASE}/integrity/#{project}/#{version}/#{path_segment(filename)}/provenance"
          http_client.get_json(url, ttl: 0, accept: INTEGRITY_ACCEPT)
        end
        aggregate(provenance_objects)
      end # rubocop:enable Lint/UnusedMethodArgument

      private

      def path_segment(value)
        CGI.escape(value).gsub("+", "%20")
      end

      def aggregate(provenance_objects)
        identities = provenance_objects.flat_map do |provenance|
          provenance.fetch("attestation_bundles", []).filter_map { |bundle| bundle_identity(bundle) }
        end
        return nil if identities.empty?

        chosen = identities.min_by do |identity|
          identity.values_at(:provenance_provider, :source_repository, :workflow_ref,
                             :commit_sha, :run_url).map(&:to_s)
        end
        chosen.merge(attestation_count: identities.sum { |identity| identity.fetch(:attestation_count) })
      end

      def bundle_identity(bundle)
        count = bundle.fetch("attestations", []).size
        publisher = bundle["publisher"]
        return if count.zero? || !publisher.is_a?(Hash) || publisher["kind"].to_s.empty?

        provider = publisher.fetch("kind").downcase
        repository = publisher["repository"] || joined_repository(publisher)
        workflow = publisher["workflow"] || publisher["workflow_filename"]
        claims = publisher["claims"].is_a?(Hash) ? publisher.fetch("claims") : {}
        workflow_ref = [workflow, claims["ref"]].compact.join("@").then { |value| value unless value.empty? }

        {
          provenance_kind: "digital_attestation",
          provenance_provider: provider,
          source_repository: repository_url(provider, repository),
          workflow_ref:,
          commit_sha: claims["sha"] || claims["commit_sha"],
          run_url: publisher["run_url"],
          attestation_count: count
        }
      end

      def joined_repository(publisher)
        owner = publisher["repository_owner"]
        name = publisher["repository_name"]
        "#{owner}/#{name}" if owner && name
      end

      def repository_url(provider, repository)
        return unless repository
        return "https://github.com/#{repository}" if provider == "github"
        return "https://gitlab.com/#{repository}" if provider == "gitlab"

        repository
      end
    end
  end
end
