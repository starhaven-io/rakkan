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
        from = whole_second(from || default_from(registry))
        to = whole_second(to)
        tracked = packages.tracked.where(registry_id: registry.id)
                          .select(:id, :name).to_a.to_h { |p| [p[:name], p[:id]] }

        cursor = from
        pages_left = MAX_PAGES_PER_RUN
        inserted = 0
        drained = true

        while cursor < to && pages_left.positive?
          window_end = [cursor + MAX_WINDOW, to].min
          batch = adapter.new_versions(from: cursor, to: window_end, max_pages: pages_left)
          validate_batch!(batch, from: cursor, to: window_end, max_pages: pages_left)
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

        # A complete window can consume the last page while later windows remain.
        drained = false if cursor < to
        registries.by_pk(registry.id).command(:update).call(feed_synced_at: cursor, updated_at: now)
        { window_from: from, window_to: to, upserts: inserted, synced_through: cursor, drained: }
      end

      private

      # RubyGems' timeframe API accepts timestamps only to whole-second
      # precision. Use that same precision for validation and cursor storage
      # so a valid entry from the transmitted boundary cannot be rejected.
      def whole_second(time)
        Time.at(time.to_i).utc
      end

      def default_from(registry)
        synced = registry.feed_synced_at
        synced ? synced.to_time - OVERLAP : Time.now.utc - MAX_WINDOW
      end

      def validate_batch!(batch, from:, to:, max_pages:)
        raise ArgumentError, "version feed result must be an object" unless batch.is_a?(Hash)

        entries = batch[:entries]
        pages = batch[:pages]
        drained = batch[:drained]
        raise ArgumentError, "version feed entries must be an array" unless entries.is_a?(Array)
        unless pages.is_a?(Integer) && pages.between?(0, max_pages)
          raise ArgumentError, "version feed page count is outside the requested budget"
        end
        raise ArgumentError, "version feed drained flag must be boolean" unless [true, false].include?(drained)

        published = entries.map do |entry|
          raise ArgumentError, "version feed entry must be an object" unless entry.is_a?(Hash)

          timestamp = entry[:published_at]
          unless timestamp.is_a?(Time) && timestamp.between?(from, to)
            raise ArgumentError, "version feed entry is outside the requested window"
          end

          timestamp
        end
        raise ArgumentError, "version feed entries must be ordered" unless published.each_cons(2).all? { |a, b| a <= b }
        return unless !drained && (published.empty? || published.max <= from)

        raise ArgumentError, "page-limited version feed made no cursor progress"
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
