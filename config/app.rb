# frozen_string_literal: true

require "hanami"
require "sequel/core"

# SQLite columns are naive timestamps; without this, Sequel hydrates them in
# the process's local zone and every stored UTC instant shifts by the UTC
# offset (silently skipping releases in incremental ingestion windows).
Sequel.default_timezone = :utc

module Rakkan
  class App < Hanami::App
    # Persistence lives in the app; the ingestion slice writes through these.
    config.shared_app_component_keys += [
      "relations.registries",
      "relations.packages",
      "relations.package_versions",
      "relations.adoption_snapshots",
      "repos.registry_repo",
      "repos.package_repo",
      "repos.adoption_snapshot_repo"
    ]
  end
end
