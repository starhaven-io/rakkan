# frozen_string_literal: true

# Ingestion entry points. Each task boots the app and calls one operation in
# the ingestion slice; see slices/ingestion/operations/.

namespace :ingest do
  desc "Load the tracked set from committed seed data (dump-derived; idempotent)"
  task :seed do
    require "hanami/boot"
    puts Ingestion::Slice["operations.seed_from_dump"].call.inspect
  end

  desc "Discover newly published versions of tracked packages (live API)"
  task :discover do
    require "hanami/boot"
    puts Ingestion::Slice["operations.discover_new_versions"].call.inspect
  end

  desc "Check provenance for unchecked versions (live API; LIMIT caps live checks)"
  task :refresh, [:limit] do |_t, args|
    require "hanami/boot"
    limit = (args[:limit] || 50).to_i
    puts Ingestion::Slice["operations.refresh_provenance"].call(limit:).inspect
  end
end

namespace :snapshot do
  desc "Record today's adoption snapshot"
  task :take do
    require "hanami/boot"
    puts Ingestion::Slice["operations.take_snapshot"].call.inspect
  end
end
