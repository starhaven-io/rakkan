# frozen_string_literal: true

module Ingestion
  module Operations
    # Compute today's adoption stats for a registry and record them,
    # replacing any snapshot already taken today (safe to re-run).
    class TakeSnapshot < Ingestion::Operation
      include Deps[
        "repos.registry_repo",
        "repos.adoption_snapshot_repo",
        "relations.packages",
        "relations.package_versions"
      ]

      # Snapshot days are UTC days, matching every other timestamp in the
      # pipeline (a local-time Date.today would mislabel evening runs in
      # western zones).
      def call(registry_name: "rubygems", taken_on: Time.now.utc.to_date)
        registry = registry_repo.by_name(registry_name)
        return { error: "unknown registry #{registry_name}" } unless registry

        tracked = packages.tracked.where(registry_id: registry.id)
        stats = {
          tracked_packages: tracked.count,
          provenant_packages: tracked.provenant.count,
          tracked_versions: version_counts(registry.id, provenant_only: false),
          provenant_versions: version_counts(registry.id, provenant_only: true)
        }

        adoption_snapshot_repo.record(registry_id: registry.id, taken_on:, **stats)
        stats.merge(taken_on:)
      end

      private

      # Versions of tracked packages, excluding yanked rows. Sequel join via
      # the dataset because the tracked flag lives on packages.
      def version_counts(registry_id, provenant_only:)
        ds = package_versions.dataset
                             .join(:packages, id: :package_id)
                             .where(Sequel[:packages][:registry_id] => registry_id)
                             .where(Sequel[:packages][:tracked] => true)
                             .where(Sequel[:package_versions][:yanked] => false)
        ds = ds.exclude(Sequel[:package_versions][:provenance_kind] => nil) if provenant_only
        ds.count
      end
    end
  end
end
