# frozen_string_literal: true

ROM::SQL.migration do
  change do
    alter_table :registries do
      # High-water mark for the registry's new-version feed: the instant up
      # to which discovery has fully processed the feed, independent of
      # whether any entry matched a tracked package.
      add_column :feed_synced_at, DateTime
    end
  end
end
