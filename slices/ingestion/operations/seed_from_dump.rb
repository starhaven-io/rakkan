# frozen_string_literal: true

module Ingestion
  module Operations
    # Bulk-load the tracked set from the adapter's seed data (dump-derived).
    # Idempotent: every write is an upsert keyed on the natural unique index,
    # so re-running converges instead of duplicating. Convergent in both
    # directions: packages absent from the current seed are untracked, and
    # dump-derived provenance never overwrites a newer live observation.
    class SeedFromDump < Ingestion::Operation
      include Deps[
        "adapters.rubygems",
        "repos.registry_repo",
        "relations.registries",
        "relations.packages",
        "relations.package_versions"
      ]

      CHUNK = 2_000

      def call(adapter: rubygems)
        # Resolve every seed stream before writing so a provenance-only
        # adapter fails at the interface boundary without leaving registry data.
        tracked_packages = adapter.each_tracked_package
        seed_versions = adapter.each_seed_version
        seed_attestations = adapter.each_seed_attestation

        now = Time.now.utc
        registry = registry_repo.find_or_create(
          name: adapter.registry_slug,
          display_name: adapter.display_name,
          url: adapter.registry_url
        )

        package_count = upsert_packages(registry.id, tracked_packages, now)
        ref_to_id = packages.where(registry_id: registry.id).select(:id, :registry_ref).to_a
                            .to_h { |p| [p[:registry_ref], p[:id]] }
        version_count = upsert_versions(ref_to_id, seed_versions, adapter, now)
        attested_count = apply_attestations(registry.id, seed_attestations, adapter, now)
        recompute_first_provenant_at(registry.id)
        advance_feed_cursor(registry, adapter, now)

        { packages: package_count, versions: version_count, attested_versions: attested_count }
      end

      private

      def upsert_packages(registry_id, tracked_packages, now)
        rows = tracked_packages.map do |pkg|
          pkg.merge(registry_id:, tracked: true, created_at: now, updated_at: now)
        end
        packages.dataset.db.transaction do
          # The tracked set is exactly the current seed: packages that fell
          # out of the top N stay for history but stop counting.
          packages.dataset.where(registry_id:)
                  .update(tracked: false, rank: nil, updated_at: now)
          rows.each_slice(CHUNK) do |chunk|
            packages.dataset.insert_conflict(
              target: %i[registry_id name],
              update: {
                rank: Sequel[:excluded][:rank],
                downloads_total: Sequel[:excluded][:downloads_total],
                registry_ref: Sequel[:excluded][:registry_ref],
                tracked: true,
                updated_at: now
              }
            ).multi_insert(chunk)
          end
        end
        rows.size
      end

      def upsert_versions(ref_to_id, seed_versions, adapter, now)
        count = 0
        # The dump's attestations table is authoritative at dump time, so
        # every seeded version starts out "checked as of the dump" rather
        # than "never checked"; only genuinely new versions need live calls.
        checked_at = adapter.seed_as_of
        seed_versions.each_slice(CHUNK) do |chunk|
          rows = chunk.filter_map do |v|
            package_id = ref_to_id[v[:package_ref]] or next
            v.except(:package_ref).merge(
              package_id:, provenance_checked_at: checked_at,
              created_at: now, updated_at: now
            )
          end
          package_versions.dataset.insert_conflict(
            target: %i[package_id number platform],
            update: {
              latest: Sequel[:excluded][:latest],
              yanked: Sequel[:excluded][:yanked],
              registry_ref: Sequel[:excluded][:registry_ref],
              published_at: Sequel[:excluded][:published_at],
              updated_at: now
            }
          ).multi_insert(rows)
          count += rows.size
        end
        count
      end

      def apply_attestations(registry_id, seed_attestations, adapter, now)
        # Stamp with the dump's own timestamp, and never regress a newer
        # observation (e.g. a live refresh that ran after the dump was cut).
        seed_at = adapter.seed_as_of || now
        registry_package_ids = packages.dataset.where(registry_id:).select(:id)
        count = 0
        seed_attestations.each do |att|
          count += package_versions.dataset
                                   .where(registry_ref: att[:version_ref], package_id: registry_package_ids)
                                   .where(
                                     Sequel.|({ provenance_checked_at: nil },
                                              Sequel[:provenance_checked_at] <= seed_at)
                                   )
                                   .update(**att[:provenance], provenance_checked_at: seed_at, updated_at: now)
        end
        count
      end

      # The dump is data-current through its own cut time, so seeding
      # establishes the feed cursor too. One conditional UPDATE against the
      # stored value (not a struct read from before the lengthy seed), so a
      # concurrent discovery run can never be regressed to the dump time.
      def advance_feed_cursor(registry, adapter, now)
        seed_at = adapter.seed_as_of
        return unless seed_at

        registries.dataset
                  .where(id: registry.id)
                  .where(Sequel.|({ feed_synced_at: nil }, Sequel[:feed_synced_at] < seed_at))
                  .update(feed_synced_at: seed_at, updated_at: now)
      end

      def recompute_first_provenant_at(registry_id)
        # One statement instead of N queries; plain SQL via the Sequel db
        # handle because ROM's DSL has no correlated-subquery update.
        packages.dataset.db.run(<<~SQL)
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
