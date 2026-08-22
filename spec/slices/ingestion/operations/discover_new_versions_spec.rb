# frozen_string_literal: true

# Feed-shaped stand-in: returns scripted batches and records every call.
class FakeFeedAdapter
  attr_reader :calls

  def initialize(slug:, batches: [])
    @slug = slug
    @batches = batches
    @calls = []
  end

  def registry_slug = @slug

  def new_versions(from:, to:, max_pages:)
    @calls << { from:, to:, max_pages: }
    @batches.shift || { entries: [], drained: true, pages: 1 }
  end
end

RSpec.describe Ingestion::Operations::DiscoverNewVersions, :db do
  subject(:operation) { Ingestion::Slice["operations.discover_new_versions"] }

  let(:versions) { Hanami.app["relations.package_versions"] }
  let(:registries) { Hanami.app["relations.registries"] }

  def entry(name, number, published_at, yanked: false)
    { package_name: name, number:, platform: "ruby", published_at:,
      prerelease: false, yanked: }
  end

  it "inserts tracked versions only, propagates yanked, and persists the cursor" do
    registry = create_registry!
    create_package!(registry, name: "psych")
    to = Time.utc(2026, 8, 14, 12)
    adapter = FakeFeedAdapter.new(slug: "rubygems", batches: [
                                    { entries: [
                                      entry("psych", "9.9.9", Time.utc(2026, 8, 14, 10)),
                                      entry("psych", "9.9.8", Time.utc(2026, 8, 14, 9), yanked: true),
                                      entry("not-tracked", "1.0.0", Time.utc(2026, 8, 14, 11))
                                    ], drained: true, pages: 1 }
                                  ])

    result = operation.call(from: Time.utc(2026, 8, 14, 8), to:, adapter:)

    expect(result).to be_success
    expect(result.value!).to include(upserts: 2, drained: true)
    expect(versions.count).to eq(2)
    expect(versions.where(number: "9.9.8").one[:yanked]).to be(true)
    expect(registries.by_pk(registry.id).one[:feed_synced_at].to_time).to eq(to)
  end

  it "walks multi-week backlog in seven-day windows instead of discarding it" do
    create_registry!
    from = Time.utc(2026, 7, 25)
    to = Time.utc(2026, 8, 14)
    adapter = FakeFeedAdapter.new(slug: "rubygems")

    result = operation.call(from:, to:, adapter:)

    expect(result.value![:synced_through]).to eq(to)
    expect(adapter.calls.size).to eq(3)
    expect(adapter.calls.map { |c| c[:to] - c[:from] }).to all(be <= 7 * 24 * 3600)
    expect(adapter.calls.first[:from]).to eq(from)
    expect(adapter.calls.last[:to]).to eq(to)
  end

  it "parks the cursor at the last processed instant when the page budget runs out" do
    registry = create_registry!
    create_package!(registry, name: "psych")
    newest_seen = Time.utc(2026, 8, 13, 6)
    adapter = FakeFeedAdapter.new(slug: "rubygems", batches: [
                                    { entries: [entry("psych", "1.0.0", newest_seen)],
                                      drained: false, pages: 500 }
                                  ])

    result = operation.call(from: Time.utc(2026, 8, 13), to: Time.utc(2026, 8, 14), adapter:)

    expect(result.value!).to include(drained: false, synced_through: newest_seen)
    expect(adapter.calls.first[:max_pages]).to eq(500)
    expect(registries.by_pk(registry.id).one[:feed_synced_at].to_time).to eq(newest_seen)
  end

  it "resumes from the persisted cursor with an overlap" do
    registry = create_registry!
    synced = Time.utc(2026, 8, 13, 12)
    registries.by_pk(registry.id).command(:update).call(feed_synced_at: synced)
    adapter = FakeFeedAdapter.new(slug: "rubygems")

    operation.call(to: Time.utc(2026, 8, 14), adapter:)

    expect(adapter.calls.first[:from]).to eq(synced - 3600)
  end

  it "scopes tracking to the adapter's registry" do
    rubygems_registry = create_registry!
    other = create_registry!(name: "cratesish")
    create_package!(other, name: "psych") # same name, different registry
    adapter = FakeFeedAdapter.new(slug: "rubygems", batches: [
                                    { entries: [entry("psych", "1.0.0", Time.utc(2026, 8, 14, 1))],
                                      drained: true, pages: 1 }
                                  ])

    result = operation.call(from: Time.utc(2026, 8, 14), to: Time.utc(2026, 8, 14, 2), adapter:)

    expect(result.value![:upserts]).to eq(0)
    expect(versions.count).to eq(0)
    expect(registries.by_pk(rubygems_registry.id).one[:feed_synced_at]).not_to be_nil
    expect(registries.by_pk(other.id).one[:feed_synced_at]).to be_nil
  end
end
