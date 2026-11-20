# frozen_string_literal: true

module Ingestion
  module Operations
    # Compute today's adoption stats for a registry and record them,
    # replacing any snapshot already taken today (safe to re-run).
    class TakeSnapshot < Ingestion::Operation
      class IncompleteObservation < StandardError; end

      include Deps[
        "repos.registry_repo",
        "repos.adoption_snapshot_repo",
        "relations.packages",
        "relations.package_versions"
      ]

      # Snapshot days are UTC days, matching every other timestamp in the
      # pipeline (a local-time Date.today would mislabel evening runs in
      # western zones).
      def call(registry_name: "rubygems", taken_on: Time.now.utc.to_date,
               waiver_date: taken_on, waivers: nil)
        registry = registry_repo.by_name(registry_name)
        raise ArgumentError, "registry #{registry_name} is not seeded; run ingest:seed first" unless registry

        waivers ||= Ingestion::ProvenanceWaivers.load(today: waiver_date)
        waivers = waivers.for_registry(registry_name)
        adapter_key = "adapters.#{registry_name}"
        available_since = Ingestion::Slice[adapter_key].provenance_available_since if Ingestion::Slice.key?(adapter_key)

        # Keep the readiness check, counts, and same-day upsert on one SQLite snapshot.
        packages.dataset.db.transaction(mode: :immediate) do
          eligible = package_versions.tracked_release_dataset(registry.id, available_since:)
          unchecked = eligible.where(Sequel[:package_versions][:provenance_checked_at] => nil)
          unless exclude_unresolved_waivers(unchecked, waivers).empty?
            raise IncompleteObservation, "#{registry_name} has unchecked tracked versions. Run ingest:refresh first."
          end

          versions = exclude_unresolved_waivers(package_versions.tracked_release_dataset(registry.id), waivers)
          tracked = packages.tracked.where(registry_id: registry.id)
          stats = {
            tracked_packages: tracked.count,
            provenant_packages: tracked.provenant.count,
            tracked_versions: versions.count,
            provenant_versions: versions.exclude(Sequel[:package_versions][:provenance_kind] => nil).count
          }
          adoption_snapshot_repo.record(registry_id: registry.id, taken_on:, **stats)
          stats.merge(taken_on:)
        end
      end

      private

      def exclude_unresolved_waivers(dataset, waivers)
        return dataset if waivers.empty?

        identities = waivers.map do |waiver|
          Sequel.&(
            { Sequel[:packages][:name] => waiver.package },
            { Sequel[:package_versions][:number] => waiver.number },
            { Sequel[:package_versions][:platform] => waiver.platform },
            { Sequel[:package_versions][:provenance_checked_at] => nil }
          )
        end
        dataset.exclude(Sequel.|(*identities))
      end
    end
  end
end
