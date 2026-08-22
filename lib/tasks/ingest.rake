# frozen_string_literal: true

# Ingestion entry points. Each task boots the app and calls one operation in
# the ingestion slice; see slices/ingestion/operations/.

module IngestionTaskSupport
  class UnsupportedOperation < StandardError; end

  UNAVAILABLE_HINTS = {
    ["ingest:seed", "pypi"] => "add a tracked seed before selecting it",
    ["ingest:discover", "cratesio"] =>
      "rebuild the daily-dump seed, then run ingest:seed[cratesio]",
    ["ingest:discover", "pypi"] =>
      "implement a durable discovery cursor before selecting it"
  }.freeze

  module_function

  def adapter(registry)
    slug = (registry || "rubygems").to_s
    key = "adapters.#{slug}"
    return Ingestion::Slice[key] if Ingestion::Slice.key?(key)

    raise ArgumentError,
          %(unknown registry "#{slug}"; valid options: #{registry_slugs.join(", ")})
  end

  def call(task_name, operation_key, adapter:, **)
    unsupported_key = [task_name, adapter.registry_slug]
    raise_unsupported(task_name, adapter, unsupported_key) if task_name == "ingest:discover" &&
                                                              !implemented?(adapter, :new_versions)

    Ingestion::Slice[operation_key].call(adapter:, **)
  rescue NotImplementedError
    raise if task_name == "ingest:discover" && implemented?(adapter, :new_versions)
    raise unless UNAVAILABLE_HINTS.key?(unsupported_key)

    raise_unsupported(task_name, adapter, unsupported_key)
  end

  def implemented?(adapter, method)
    adapter.method(method).owner != Ingestion::Adapters::RegistryAdapter
  end

  def raise_unsupported(task_name, adapter, unsupported_key)
    hint = UNAVAILABLE_HINTS.fetch(unsupported_key)
    raise UnsupportedOperation,
          "#{task_name} is unavailable for registry #{adapter.registry_slug}; #{hint}",
          cause: nil
  end

  def registry_slugs
    Ingestion::Slice.keys.filter_map do |key|
      key.delete_prefix("adapters.") if key.match?(/\Aadapters\.[^.]+\z/)
    end.sort
  end
end

namespace :ingest do
  desc "Load the tracked set from committed seed data (dump-derived; idempotent)"
  task :seed, [:registry] do |_task, args|
    require "hanami/boot"
    adapter = IngestionTaskSupport.adapter(args[:registry])
    result = IngestionTaskSupport.call(
      "ingest:seed", "operations.seed_from_dump", adapter:
    )
    puts result.inspect
  end

  desc "Discover newly published versions of tracked packages (live API)"
  task :discover, [:registry] do |_task, args|
    require "hanami/boot"
    adapter = IngestionTaskSupport.adapter(args[:registry])
    result = IngestionTaskSupport.call(
      "ingest:discover", "operations.discover_new_versions", adapter:
    )
    puts result.inspect
  end

  desc "Check provenance for unchecked versions (live API; LIMIT caps live checks)"
  task :refresh, %i[limit registry] do |_task, args|
    require "hanami/boot"
    limit = (args[:limit] || 50).to_i
    adapter = IngestionTaskSupport.adapter(args[:registry])
    result = IngestionTaskSupport.call(
      "ingest:refresh", "operations.refresh_provenance", adapter:, limit:
    )
    puts result.inspect
  end
end

namespace :snapshot do
  desc "Record today's adoption snapshot"
  task :take, [:registry] do |_task, args|
    require "hanami/boot"
    adapter = IngestionTaskSupport.adapter(args[:registry])
    result = Ingestion::Slice["operations.take_snapshot"].call(
      registry_name: adapter.registry_slug
    )
    puts result.inspect
  end
end
