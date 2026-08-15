# frozen_string_literal: true

module Rakkan
  module Structs
    class PackageVersion < Rakkan::DB::Struct
      def provenant? = !provenance_kind.nil?
    end
  end
end
