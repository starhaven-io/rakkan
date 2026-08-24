# frozen_string_literal: true

module Ingestion
  module Operations
    # Ask the registry for provenance on versions we have not checked yet
    # (or not recently). Resumable by construction: each version's row is
    # updated as soon as it is checked, so an interrupted run just continues
    # where it stopped. `limit` caps the versions put to the live API per run.
    # Adapters may batch versions when one response can answer several of them;
    # registries with per-file provenance may instead make several requests per
    # version. Versions published before the registry could record provenance
    # are settled in bulk outside that cap, since they cost no requests.
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
        available_since = adapter.provenance_available_since
        settled = settle_predating(registry.id, available_since, now)
        checked = 0
        found = 0

        candidate_batches(registry.id, stale_after, limit, available_since, now).each do |name, rows|
          adapter.each_provenance(name:, versions: rows) do |row, provenance|
            attrs = (provenance || NO_PROVENANCE.dup)
                    .merge(provenance_checked_at: now, updated_at: now)
            package_versions.by_pk(row[:id]).command(:update).call(attrs)
            checked += 1
            found += 1 if provenance
          end
        end

        recompute_first_provenant_at(registry.id)
        remaining = candidate_scope(registry.id, stale_after, available_since, now).count
        { checked:, provenant: found, settled:, remaining: }
      end

      private

      # Versions published before the registry could record provenance at all
      # are settled in one statement rather than one request each. Spending a
      # run's live budget on them would be waste: the mechanism did not exist,
      # so the answer is already known. A null published_at is left alone --
      # an unknown publish time cannot rule provenance out.
      def settle_predating(registry_id, available_since, now)
        return 0 unless available_since

        tracked_ids = packages.dataset.where(registry_id:, tracked: true).select(:id)
        package_versions.dataset
                        .where(package_id: tracked_ids, provenance_checked_at: nil)
                        .where(Sequel[:published_at] < available_since)
                        .update(**NO_PROVENANCE, provenance_checked_at: now, updated_at: now)
      end

      # Unchecked (or stale) versions of this registry's tracked packages,
      # newest first so fresh releases get provenance quickly. Sequel join
      # because the package name lives on packages.
      def candidates(registry_id, stale_after, limit, available_since, now)
        candidate_scope(registry_id, stale_after, available_since, now)
          .select(
            Sequel[:package_versions][:id],
            Sequel[:packages][:name],
            Sequel[:package_versions][:number],
            Sequel[:package_versions][:platform]
          )
          .order(Sequel.desc(Sequel[:package_versions][:published_at]))
          .limit(limit)
      end

      def candidate_batches(registry_id, stale_after, limit, available_since, now)
        candidates(registry_id, stale_after, limit, available_since, now).to_a.group_by do |row|
          row[:name]
        end
      end

      # The workflow consumes this count from the operation result instead of
      # maintaining a second copy of the eligibility rules in shell SQL.
      def candidate_scope(registry_id, stale_after, available_since, now)
        ds = package_versions.dataset
                             .join(:packages, id: :package_id)
                             .where(Sequel[:packages][:registry_id] => registry_id)
                             .where(Sequel[:packages][:tracked] => true)
        if available_since
          ds = ds.where(
            Sequel.|(
              Sequel[:package_versions][:published_at] >= available_since,
              { Sequel[:package_versions][:published_at] => nil }
            )
          )
        end
        if stale_after
          ds.where do
            (Sequel[:package_versions][:provenance_checked_at] =~ nil) |
              (Sequel[:package_versions][:provenance_checked_at] < now - stale_after)
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
