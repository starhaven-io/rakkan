# frozen_string_literal: true

module Rakkan
  module Relations
    class Registries < Rakkan::DB::Relation
      schema :registries, infer: true do
        associations do
          has_many :packages
        end
      end
    end
  end
end
