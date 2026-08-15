# frozen_string_literal: true

require "tmpdir"

RSpec.describe Ingestion::Operations::SeedFromDump, :db do
  subject(:operation) { Ingestion::Slice["operations.seed_from_dump"] }

  let(:adapter) do
    Ingestion::Adapters::Rubygems.new(
      seed_dir: fixture_path("seed", "rubygems"),
      http_client: FixtureHelpers::FakeHTTPClient.new
    )
  end

  let(:packages) { Hanami.app["relations.packages"] }
  let(:versions) { Hanami.app["relations.package_versions"] }

  it "loads packages, versions, and provenance from seed data" do
    result = operation.call(adapter:)

    expect(result).to be_success
    stats = result.value!
    expect(stats[:packages]).to eq(3)
    expect(stats[:versions]).to eq(18)
    expect(stats[:attested_versions]).to eq(versions.provenant.count)
    expect(stats[:attested_versions]).to be > 0

    psych = Hanami.app["repos.package_repo"].find(packages.first[:registry_id], "psych")
    expect(psych.first_provenant_at).not_to be_nil
    expect(versions.where(provenance_checked_at: nil).count).to eq(0)
  end

  it "is idempotent across reruns" do
    operation.call(adapter:)
    first_counts = [packages.count, versions.count, versions.provenant.count]

    result = operation.call(adapter:)

    expect(result).to be_success
    expect([packages.count, versions.count, versions.provenant.count]).to eq(first_counts)
  end

  it "stamps seed provenance with the dump's timestamp, not run time" do
    operation.call(adapter:)

    checked = versions.provenant.to_a.map { |v| v[:provenance_checked_at].to_time }
    expect(checked).to all(eq(adapter.seed_as_of))
  end

  it "advances the feed cursor to the dump time without regressing a live one" do
    registries = Hanami.app["relations.registries"]

    operation.call(adapter:)
    registry_id = packages.first[:registry_id]
    expect(registries.by_pk(registry_id).one[:feed_synced_at].to_time).to eq(adapter.seed_as_of)

    ahead = adapter.seed_as_of + 7200
    registries.by_pk(registry_id).command(:update).call(feed_synced_at: ahead)
    operation.call(adapter:)

    expect(registries.by_pk(registry_id).one[:feed_synced_at].to_time).to eq(ahead)
  end

  it "untracks packages that leave the tracked set" do
    operation.call(adapter:)

    Dir.mktmpdir("rakkan-seed") do |dir|
      FileUtils.cp_r(Dir[File.join(fixture_path("seed", "rubygems"), "*")], dir)
      top = File.join(dir, "top_1000.tsv")
      File.write(top, File.readlines(top).reject { |l| l.split("\t")[2] == "rack" }.join)
      shrunk = Ingestion::Adapters::Rubygems.new(seed_dir: dir, http_client: FixtureHelpers::FakeHTTPClient.new)

      operation.call(adapter: shrunk)
    end

    repo = Hanami.app["repos.package_repo"]
    registry_id = packages.first[:registry_id]
    expect(repo.find(registry_id, "rack")).to have_attributes(tracked: false, rank: nil)
    expect(repo.find(registry_id, "psych").tracked).to be(true)
    expect(packages.tracked.count).to eq(2)
  end

  it "does not let an old dump overwrite a newer live observation" do
    operation.call(adapter:)
    live_at = adapter.seed_as_of + 3600
    attested = versions.provenant.to_a.first
    versions.by_pk(attested[:id]).command(:update).call(
      provenance_provider: "live-observation", provenance_checked_at: live_at
    )

    operation.call(adapter:)

    row = versions.by_pk(attested[:id]).one
    expect(row[:provenance_provider]).to eq("live-observation")
    expect(row[:provenance_checked_at].to_time).to eq(live_at)
  end
end
