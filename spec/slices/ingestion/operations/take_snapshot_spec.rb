# frozen_string_literal: true

RSpec.describe Ingestion::Operations::TakeSnapshot, :db do
  subject(:operation) { Ingestion::Slice["operations.take_snapshot"] }

  it "records adoption stats for the day" do
    registry = create_registry!
    provenant = create_package!(registry, name: "psych", first_provenant_at: Time.utc(2026, 1, 1))
    create_version!(provenant, number: "5.1.0",
                               provenance: { provenance_kind: "sigstore_attestation", attestation_count: 1 })
    create_version!(provenant, number: "5.0.0")
    plain = create_package!(registry, name: "rack")
    create_version!(plain, number: "3.2.7")
    create_version!(plain, number: "3.2.6", yanked: true)

    result = operation.call(taken_on: Date.new(2026, 8, 14))

    expect(result).to be_success
    expect(result.value!).to include(
      tracked_packages: 2,
      provenant_packages: 1,
      tracked_versions: 3, # yanked rows excluded
      provenant_versions: 1
    )

    snapshot = Hanami.app["repos.adoption_snapshot_repo"].latest(registry.id)
    expect(snapshot).to have_attributes(taken_on: Date.new(2026, 8, 14), provenant_packages: 1)
  end

  it "dates snapshots by UTC day regardless of process timezone" do
    old_tz = ENV.fetch("TZ", nil)
    ENV["TZ"] = "America/Los_Angeles"
    create_registry!
    # Frozen at an instant where the UTC and local dates differ, so a
    # regression to local-date stamping cannot pass by coincidence.
    allow(Time).to receive(:now).and_return(Time.utc(2026, 1, 1, 3, 0, 0))

    result = operation.call

    expect(result.value![:taken_on]).to eq(Date.new(2026, 1, 1))
  ensure
    ENV["TZ"] = old_tz
  end

  it "fails cleanly for an unknown registry" do
    result = operation.call(registry_name: "krates")

    expect(result).to be_success
    expect(result.value!).to include(error: "unknown registry krates")
  end
end
