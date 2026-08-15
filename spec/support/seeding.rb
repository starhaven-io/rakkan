# frozen_string_literal: true

# Minimal direct-to-database seeding for specs that need rows without
# running the full ingestion pipeline.
module SpecSeeding
  def create_registry!(name: "rubygems")
    Hanami.app["repos.registry_repo"].find_or_create(
      name:, display_name: "RubyGems.org", url: "https://rubygems.org"
    )
  end

  def create_package!(registry, name:, rank: 1, downloads: 1000, first_provenant_at: nil)
    now = Time.now
    Hanami.app["relations.packages"].changeset(
      :create,
      registry_id: registry.id, name:, rank:, downloads_total: downloads,
      tracked: true, first_provenant_at:, created_at: now, updated_at: now
    ).commit
    Hanami.app["repos.package_repo"].find(registry.id, name)
  end

  # Returns the new row's id.
  def create_version!(package, number:, platform: "ruby", provenance: nil, **attrs)
    now = Time.now
    Hanami.app["relations.package_versions"].changeset(
      :create,
      {
        package_id: package.id, number:, platform:,
        published_at: now, prerelease: false, latest: false, yanked: false,
        created_at: now, updated_at: now
      }.merge(provenance || {}).merge(attrs)
    ).commit[:id]
  end

  def create_snapshot!(registry, taken_on: Date.today, tracked: 100, provenant: 10,
                       tracked_versions: 1000, provenant_versions: 50)
    Hanami.app["repos.adoption_snapshot_repo"].record(
      registry_id: registry.id, taken_on:,
      tracked_packages: tracked, provenant_packages: provenant,
      tracked_versions:, provenant_versions:
    )
  end
end

RSpec.configure do |config|
  config.include SpecSeeding, :db
end
