# frozen_string_literal: true

ROM::SQL.migration do
  change do
    create_table :packages do
      primary_key :id
      foreign_key :registry_id, :registries, null: false, on_delete: :cascade
      column :name, String, null: false
      # The registry's own identifier for this package (e.g. rubygems.id from
      # the data dump), kept so dump rows can be joined without name lookups.
      column :registry_ref, String
      column :downloads_total, :Bignum
      # Rank within the tracked set at last seed/refresh; null for packages
      # that fell out of the tracked set but are kept for history.
      column :rank, Integer
      column :tracked, TrueClass, null: false, default: true
      # Earliest published_at among this package's provenant versions,
      # maintained at ingest time so "recent conversions" is a plain query.
      column :first_provenant_at, DateTime
      column :created_at, DateTime, null: false
      column :updated_at, DateTime, null: false

      index %i[registry_id name], unique: true
      index %i[registry_id rank]
      index :first_provenant_at
    end
  end
end
