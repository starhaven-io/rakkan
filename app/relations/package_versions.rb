# frozen_string_literal: true

module Rakkan
  module Relations
    class PackageVersions < Rakkan::DB::Relation
      schema :package_versions, infer: true do
        associations do
          belongs_to :package
        end
      end

      def provenant = exclude(provenance_kind: nil)

      def newest_first = order { published_at.desc }

      def tracked_release_dataset(registry_id, available_since: nil)
        versions = dataset.join(:packages, id: :package_id)
                          .where(Sequel[:packages][:registry_id] => registry_id,
                                 Sequel[:packages][:tracked] => true,
                                 Sequel[:package_versions][:yanked] => false)
        return versions unless available_since

        published_at = Sequel[:package_versions][:published_at]
        versions.where(Sequel.|(published_at >= available_since, { published_at => nil }))
      end
    end
  end
end
