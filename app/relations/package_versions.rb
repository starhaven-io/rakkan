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
    end
  end
end
