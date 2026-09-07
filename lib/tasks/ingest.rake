# frozen_string_literal: true

require "date"
require "json"

# Ingestion entry points. Each task boots the app and calls one operation in
# the ingestion slice; see slices/ingestion/operations/.

module IngestionTaskSupport
  class UnsupportedOperation < StandardError; end
  class IncompleteDiscovery < StandardError; end

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

    result = Ingestion::Slice[operation_key].call(adapter:, **)
    raise_incomplete_discovery(task_name, result)
    result
  rescue NotImplementedError
    raise if task_name == "ingest:discover" && implemented?(adapter, :new_versions)
    raise unless UNAVAILABLE_HINTS.key?(unsupported_key)

    raise_unsupported(task_name, adapter, unsupported_key)
  end

  def implemented?(adapter, method)
    adapter.method(method).owner != Ingestion::Adapters::RegistryAdapter
  end

  def raise_incomplete_discovery(task_name, result)
    return unless task_name == "ingest:discover" && result.respond_to?(:value!)

    payload = result.value!
    return unless payload.is_a?(Hash) && payload[:drained] == false

    raise IncompleteDiscovery,
          "ingest:discover exhausted its page budget at #{payload[:synced_through]}; " \
          "rerun to resume from the persisted cursor"
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

  def utc_date(value)
    return Time.now.utc.to_date unless value

    date = Date.iso8601(value.to_s)
    return date if date.iso8601 == value

    raise Date::Error
  rescue Date::Error
    raise ArgumentError, %(invalid UTC run date "#{value}"; expected YYYY-MM-DD), cause: nil
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

  desc "Check provenance (live API; LIMIT caps ordinary checks, not exact waiver probes)"
  task :refresh, %i[limit registry run_date] do |_task, args|
    require "hanami/boot"
    limit = (args[:limit] || 50).to_i
    adapter = IngestionTaskSupport.adapter(args[:registry])
    run_date = IngestionTaskSupport.utc_date(args[:run_date])
    result = IngestionTaskSupport.call(
      "ingest:refresh", "operations.refresh_provenance", adapter:, limit:, waiver_date: run_date
    )
    puts JSON.generate(result.value!)
  end
end

namespace :snapshot do
  desc "Remove known RubyGems observations mislabeled by the former normalization step"
  task :repair_rubygems_history do
    require "hanami/boot"
    result = Ingestion::Slice["operations.repair_rubygems_snapshots"].call
    puts JSON.generate(result.value!)
  end

  desc "Record today's adoption snapshot"
  task :take, %i[registry run_date] do |_task, args|
    require "hanami/boot"
    adapter = IngestionTaskSupport.adapter(args[:registry])
    run_date = IngestionTaskSupport.utc_date(args[:run_date])
    result = Ingestion::Slice["operations.take_snapshot"].call(
      registry_name: adapter.registry_slug, taken_on: run_date, waiver_date: run_date
    )
    puts result.inspect
  end
end
