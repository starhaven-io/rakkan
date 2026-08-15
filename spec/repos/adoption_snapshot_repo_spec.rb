# frozen_string_literal: true

RSpec.describe Rakkan::Repos::AdoptionSnapshotRepo, :db do
  subject(:repo) { Hanami.app["repos.adoption_snapshot_repo"] }

  let(:registry) { create_registry! }

  it "keeps one snapshot per registry and day, replacing on re-run" do
    create_snapshot!(registry, taken_on: Date.new(2026, 8, 13), provenant: 10)
    create_snapshot!(registry, taken_on: Date.new(2026, 8, 14), provenant: 11)
    create_snapshot!(registry, taken_on: Date.new(2026, 8, 14), provenant: 12)

    series = repo.series(registry.id)
    expect(series.map(&:taken_on)).to eq([Date.new(2026, 8, 13), Date.new(2026, 8, 14)])
    expect(repo.latest(registry.id)).to have_attributes(provenant_packages: 12)
  end
end
