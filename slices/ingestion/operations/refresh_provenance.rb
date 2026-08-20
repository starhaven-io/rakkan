# frozen_string_literal: true

module Ingestion
  module Operations
    # Ask the registry for provenance on versions we have not checked yet
    # (or not recently). Resumable by construction: each version's row is
    # updated as soon as it is checked, so an interrupted run just continues
    # where it stopped. `limit` caps the number of versions checked per run;
    # registries with per-file provenance may make several requests per version.
    # Convergent with registry state: checks bypass the response cache, and
    # a negative answer clears any previously stored provenance.
    class RefreshProvenance < Ingestion::Operation
      include Deps[
        "adapters.rubygems",
        "repos.registry_repo",
        "relations.packages",
        "relations.package_versions"
      ]

      NO_PROVENANCE = {
        provenance_kind: nil, provenance_provider: nil, source_repository: nil,
        workflow_ref: nil, commit_sha: nil, run_url: nil, attestation_count: 0
      }.freeze

      def call(limit: 50, stale_after: nil, adapter: rubygems)
        registry = registry_repo.by_name(adapter.registry_slug)
        return { error: "unknown registry #{adapter.registry_slug}" } unless registry

        now = Time.now.utc
        checked = 0
        found = 0

        candidates(registry.id, stale_after, limit).each do |row|
          provenance = adapter.fetch_provenance(
            name: row[:name], number: row[:number], platform: row[:platform]
          )
          attrs = (provenance || NO_PROVENANCE.dup)
                  .merge(provenance_checked_at: now, updated_at: now)
          package_versions.by_pk(row[:id]).command(:update).call(attrs)
          checked += 1
          found += 1 if provenance
        end

        recompute_first_provenant_at(registry.id)
        { checked:, provenant: found }
      end

      private

      # Unchecked (or stale) versions of this registry's tracked packages,
      # newest first so fresh releases get provenance quickly. Sequel join
      # because the package name lives on packages.
      def candidates(registry_id, stale_after, limit)
        ds = package_versions.dataset
                             .join(:packages, id: :package_id)
                             .where(Sequel[:packages][:registry_id] => registry_id)
                             .where(Sequel[:packages][:tracked] => true)
                             .select(
                               Sequel[:package_versions][:id],
                               Sequel[:packages][:name],
                               Sequel[:package_versions][:number],
                               Sequel[:package_versions][:platform]
                             )
                             .order(Sequel.desc(Sequel[:package_versions][:published_at]))
                             .limit(limit)
        if stale_after
          ds.where do
            (Sequel[:package_versions][:provenance_checked_at] =~ nil) |
              (Sequel[:package_versions][:provenance_checked_at] < Time.now.utc - stale_after)
          end
        else
          ds.where(Sequel[:package_versions][:provenance_checked_at] => nil)
        end
      end

      def recompute_first_provenant_at(registry_id)
        package_versions.dataset.db.run(<<~SQL)
          UPDATE packages
          SET first_provenant_at = (
            SELECT MIN(pv.published_at) FROM package_versions pv
            WHERE pv.package_id = packages.id AND pv.provenance_kind IS NOT NULL
          )
          WHERE registry_id = #{Integer(registry_id)}
        SQL
      end
    end
  end
end
