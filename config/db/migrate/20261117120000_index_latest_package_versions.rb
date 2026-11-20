# frozen_string_literal: true

ROM::SQL.migration do
  change do
    alter_table :package_versions do
      add_index :package_id, name: :package_versions_latest_by_package_index, where: { latest: true, yanked: false }
    end
  end
end
