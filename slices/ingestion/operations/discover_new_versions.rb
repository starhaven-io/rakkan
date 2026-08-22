# frozen_string_literal: true

module Ingestion
  module Operations
    # Walk the registry's new-version feed from the persisted high-water
    # mark to now, in windows the API allows, inserting versions of tracked
    # packages. The cursor (registries.feed_synced_at) only advances over
    # fully processed feed ranges, so backlog is never silently skipped:
    # an interrupted or page-capped run resumes where it stopped.
    class DiscoverNewVersions < Ingestion::Operation
      include Deps[
        "adapters.rubygems",
        "repos.registry_repo",
        "relations.registries",
        "relations.packages",
        "relations.package_versions"
      ]

      # timeframe_versions allows at most a 7-day window per request.
      MAX_WINDOW = 7 * 24 * 3600
      # Re-cover the boundary so publishes racing the previous run are seen;
      # upserts make the overlap harmless.
      OVERLAP = 3600
      # Weekly production runs must drain a full seven-day window. At the
      # API's 30 entries per page, this covers 15,000 releases with headroom
      # above the 8,306 releases observed during 2026-08-10..17.
      MAX_PAGES_PER_RUN = 500

      def call(from: nil, to: Time.now.utc, adapter: rubygems)
        registry = registry_repo.by_name(adapter.registry_slug)
        return { error: "unknown registry #{adapter.registry_slug}" } unless registry

        now = Time.now.utc
        from ||= default_from(registry)
        tracked = packages.tracked.where(registry_id: registry.id)
                          .select(:id, :name).to_a.to_h { |p| [p[:name], p[:id]] }

        cursor = from
        pages_left = MAX_PAGES_PER_RUN
        inserted = 0
        drained = true

        while cursor < to && pages_left.positive?
          window_end = [cursor + MAX_WINDOW, to].min
          batch = adapter.new_versions(from: cursor, to: window_end, max_pages: pages_left)
          pages_left -= [batch[:pages], 1].max

          batch[:entries].each do |v|
            package_id = tracked[v[:package_name]] or next
            upsert_version(package_id, v, now)
            inserted += 1
          end

          if batch[:drained]
            cursor = window_end
          else
            # Feed order is ascending (see adapter), so everything up to the
            # newest entry seen has been processed.
            cursor = batch[:entries].map { |v| v[:published_at] }.max || cursor
            drained = false
            break
          end
        end

        registries.by_pk(registry.id).command(:update).call(feed_synced_at: cursor, updated_at: now)
        { window_from: from, window_to: to, upserts: inserted, synced_through: cursor, drained: }
      end

      private

      def default_from(registry)
        synced = registry.feed_synced_at
        synced ? synced.to_time - OVERLAP : Time.now.utc - MAX_WINDOW
      end

      def upsert_version(package_id, entry, now)
        package_versions.dataset.insert_conflict(
          target: %i[package_id number platform],
          update: {
            yanked: Sequel[:excluded][:yanked],
            prerelease: Sequel[:excluded][:prerelease],
            published_at: Sequel[:excluded][:published_at],
            updated_at: now
          }
        ).insert(
          package_id:,
          number: entry[:number],
          platform: entry[:platform],
          published_at: entry[:published_at],
          prerelease: entry[:prerelease],
          yanked: entry[:yanked],
          created_at: now,
          updated_at: now
        )
      end
    end
  end
end
