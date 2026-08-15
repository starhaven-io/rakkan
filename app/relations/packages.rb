# frozen_string_literal: true

module Rakkan
  module Relations
    class Packages < Rakkan::DB::Relation
      schema :packages, infer: true do
        associations do
          belongs_to :registry
          has_many :package_versions
        end
      end

      def tracked = where(tracked: true)

      def provenant = exclude(first_provenant_at: nil)

      def by_rank = order(:rank)
    end
  end
end
