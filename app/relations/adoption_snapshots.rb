# frozen_string_literal: true

module Rakkan
  module Relations
    class AdoptionSnapshots < Rakkan::DB::Relation
      schema :adoption_snapshots, infer: true do
        associations do
          belongs_to :registry
        end
      end

      def chronological = order(:taken_on)
    end
  end
end
