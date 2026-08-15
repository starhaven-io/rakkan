# frozen_string_literal: true

module Rakkan
  module Repos
    class PackageRepo < Rakkan::DB::Repo
      # LIKE/GLOB metacharacters that must not act as wildcards in user input.
      LIKE_WILDCARDS = /[\\%_]/

      def find(registry_id, name)
        packages.where(registry_id:, name:).one
      end

      def search(registry_id, query, limit: 50)
        escaped = query.gsub(LIKE_WILDCARDS) { |c| "\\#{c}" }
        packages
          .tracked
          .where(registry_id:)
          .where { name.ilike("%#{escaped}%") }
          .order { downloads_total.desc }
          .limit(limit)
          .to_a
      end

      def top_by_downloads(registry_id, limit: 25)
        packages.tracked.where(registry_id:).by_rank.limit(limit).to_a
      end

      def all_tracked(registry_id)
        packages.tracked.where(registry_id:).by_rank.to_a
      end

      def recent_conversions(registry_id, limit: 10)
        packages
          .tracked
          .where(registry_id:)
          .provenant
          .order { first_provenant_at.desc }
          .limit(limit)
          .to_a
      end

      def versions_of(package_id)
        package_versions.where(package_id:).newest_first.to_a
      end
    end
  end
end
