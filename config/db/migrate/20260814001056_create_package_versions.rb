# frozen_string_literal: true

ROM::SQL.migration do
  change do
    create_table :package_versions do
      primary_key :id
      foreign_key :package_id, :packages, null: false, on_delete: :cascade
      column :number, String, null: false
      # Platform qualifier; part of the version identity on RubyGems
      # ("ruby", "java", "arm64-darwin", ...). Registries without the
      # concept leave it as the empty string; adapters with one must
      # supply it explicitly.
      column :platform, String, null: false, default: ""
      # The registry's own version identifier (versions.id in the RubyGems
      # dump); attestation rows reference it directly.
      column :registry_ref, String
      column :published_at, DateTime
      column :prerelease, TrueClass, null: false, default: false
      column :latest, TrueClass, null: false, default: false
      column :yanked, TrueClass, null: false, default: false

      # Provenance block, shaped by the source investigation (DATA_SOURCES.md).
      # Null provenance_kind means "no provenance signal observed".
      # Open text keeps registry-specific signals additive without migrations.
      column :provenance_kind, String
      column :provenance_provider, String
      column :source_repository, String
      column :workflow_ref, String
      column :commit_sha, String
      column :run_url, String
      column :attestation_count, Integer, null: false, default: 0
      # When we last asked the registry about this version's provenance; lets
      # incremental runs skip versions checked recently.
      column :provenance_checked_at, DateTime

      column :created_at, DateTime, null: false
      column :updated_at, DateTime, null: false

      index %i[package_id number platform], unique: true
      index %i[package_id provenance_kind]
      index :published_at
    end
  end
end
