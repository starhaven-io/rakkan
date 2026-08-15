# frozen_string_literal: true

module Rakkan
  module Repos
    class AdoptionSnapshotRepo < Rakkan::DB::Repo
      def latest(registry_id)
        adoption_snapshots.where(registry_id:).order { taken_on.desc }.limit(1).one
      end

      def series(registry_id)
        adoption_snapshots.where(registry_id:).chronological.to_a
      end

      # One snapshot per (registry, day). A single upsert (rather than
      # delete-then-create) so a crash or a concurrent run can neither drop
      # the prior snapshot nor race the unique index.
      def record(registry_id:, taken_on:, **stats)
        adoption_snapshots.dataset.insert_conflict(
          target: %i[registry_id taken_on],
          update: stats.keys.to_h { |k| [k, Sequel[:excluded][k]] }
                       .merge(created_at: Sequel[:excluded][:created_at])
        ).insert(registry_id:, taken_on:, **stats, created_at: Time.now.utc)
        adoption_snapshots.where(registry_id:, taken_on:).one
      end
    end
  end
end
