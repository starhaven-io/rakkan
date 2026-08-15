# frozen_string_literal: true

module Rakkan
  module Structs
    class Package < Rakkan::DB::Struct
      def provenant? = !first_provenant_at.nil?
    end
  end
end
