# frozen_string_literal: true

module Rakkan
  module Repos
    class RegistryRepo < Rakkan::DB::Repo
      commands :create

      def by_name(name)
        registries.where(name:).one
      end

      def find_or_create(name:, display_name:, url:)
        by_name(name) || create(
          name:, display_name:, url:,
          created_at: Time.now, updated_at: Time.now
        )
      end
    end
  end
end
