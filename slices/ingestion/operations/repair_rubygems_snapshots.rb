# frozen_string_literal: true

module Ingestion
  module Operations
    # Remove observations created while refresh-data relabeled a single
    # 2026-08-10 tracked set as later weekly dumps. The explicit dates and
    # creation cutoff make the correction auditable without deleting a later
    # legitimate observation for one of those dump dates.
    class RepairRubygemsSnapshots < Ingestion::Operation
      include Deps["repos.registry_repo", "relations.adoption_snapshots"]

      MISLABELED_DATES = [Date.new(2026, 8, 17), Date.new(2026, 8, 24), Date.new(2026, 8, 31)].freeze
      LEGACY_CREATED_BEFORE = Time.utc(2026, 9, 7).freeze

      def call
        registry = registry_repo.by_name("rubygems")
        return { deleted: 0 } unless registry

        scope = adoption_snapshots.dataset
                                  .where(registry_id: registry.id, taken_on: MISLABELED_DATES)
                                  .where(Sequel[:created_at] < LEGACY_CREATED_BEFORE)
        deleted = scope.count
        scope.delete
        { deleted: }
      end
    end
  end
end
