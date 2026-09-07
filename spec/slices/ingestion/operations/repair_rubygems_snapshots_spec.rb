# frozen_string_literal: true

RSpec.describe Ingestion::Operations::RepairRubygemsSnapshots, :db do
  subject(:operation) { Ingestion::Slice["operations.repair_rubygems_snapshots"] }

  it "removes only the known mislabeled RubyGems observations" do
    rubygems = create_registry!
    crates = create_registry!(name: "cratesio")
    valid = Date.new(2026, 8, 10)
    invalid = Date.new(2026, 8, 17)
    create_snapshot!(rubygems, taken_on: valid)
    create_snapshot!(rubygems, taken_on: invalid)
    create_snapshot!(crates, taken_on: invalid)
    Hanami.app["relations.adoption_snapshots"].dataset
          .where(registry_id: rubygems.id, taken_on: invalid)
          .update(created_at: described_class::LEGACY_CREATED_BEFORE - 1)

    expect(operation.call.value!).to eq(deleted: 1)
    expect(Hanami.app["relations.adoption_snapshots"].to_a.map { |row| [row[:registry_id], row[:taken_on]] })
      .to contain_exactly([rubygems.id, valid], [crates.id, invalid])

    create_snapshot!(rubygems, taken_on: invalid)
    Hanami.app["relations.adoption_snapshots"].dataset
          .where(registry_id: rubygems.id, taken_on: invalid)
          .update(created_at: described_class::LEGACY_CREATED_BEFORE + 1)

    expect(operation.call.value!).to eq(deleted: 0)
    expect(Hanami.app["relations.adoption_snapshots"].where(registry_id: rubygems.id).count).to eq(2)
  end

  it "is idempotent when there is no RubyGems history" do
    expect(operation.call.value!).to eq(deleted: 0)
  end
end
