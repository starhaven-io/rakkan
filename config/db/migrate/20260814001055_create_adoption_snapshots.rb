# frozen_string_literal: true

ROM::SQL.migration do
  change do
    create_table :adoption_snapshots do
      primary_key :id
      foreign_key :registry_id, :registries, null: false, on_delete: :cascade
      column :taken_on, Date, null: false
      column :tracked_packages, Integer, null: false
      column :provenant_packages, Integer, null: false
      column :tracked_versions, Integer, null: false
      column :provenant_versions, Integer, null: false
      column :created_at, DateTime, null: false

      index %i[registry_id taken_on], unique: true
    end
  end
end
