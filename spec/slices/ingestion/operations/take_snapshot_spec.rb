# frozen_string_literal: true

RSpec.describe Ingestion::Operations::TakeSnapshot, :db do
  subject(:operation) { Ingestion::Slice["operations.take_snapshot"] }

  it "checks and records the observation in an immediate transaction" do
    create_registry!
    db = Hanami.app["relations.packages"].dataset.db
    allow(db).to receive(:transaction).and_call_original

    operation.call

    expect(db).to have_received(:transaction).with(mode: :immediate)
  end

  it "records adoption stats for the day" do
    registry = create_registry!
    provenant = create_package!(registry, name: "psych", first_provenant_at: Time.utc(2026, 1, 1))
    checked_at = Time.utc(2026, 8, 14)
    create_version!(provenant, number: "5.1.0",
                               provenance_checked_at: checked_at,
                               provenance: { provenance_kind: "sigstore_attestation", attestation_count: 1 })
    create_version!(provenant, number: "5.0.0", provenance_checked_at: checked_at)
    plain = create_package!(registry, name: "rack")
    create_version!(plain, number: "3.2.7", provenance_checked_at: checked_at)
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

  let(:psych_waiver) do
    Ingestion::ProvenanceWaivers::Entry.new(
      registry: "rubygems", package: "psych", number: "5.1.0", platform: "ruby",
      reason: "Registry permanently omits this historical version", expires_on: Date.new(2026, 12, 1)
    )
  end

  it "excludes unresolved exact 404 waivers from the version denominator" do
    registry = create_registry!
    pkg = create_package!(registry, name: "psych")
    create_version!(pkg, number: "5.1.0", provenance_checked_at: nil)
    expect(Ingestion::ProvenanceWaivers).to receive(:load)
      .with(today: Date.new(2026, 9, 7))
      .and_return(Ingestion::ProvenanceWaivers.new([psych_waiver]))

    result = operation.call(taken_on: Date.new(2026, 9, 7))

    expect(result.value!).to include(tracked_versions: 0, provenant_versions: 0)
  end

  it "counts a waived version again once the registry has answered for it" do
    registry = create_registry!
    pkg = create_package!(registry, name: "psych")
    create_version!(
      pkg, number: "5.1.0", provenance_checked_at: Time.utc(2026, 9, 6),
           provenance: { provenance_kind: "sigstore_attestation", attestation_count: 1 }
    )

    result = operation.call(
      taken_on: Date.new(2026, 9, 7), waivers: Ingestion::ProvenanceWaivers.new([psych_waiver])
    )

    expect(result.value!).to include(tracked_versions: 1, provenant_versions: 1)
  end

  it "preserves a complete same-day snapshot until every eligible release has an observation" do
    registry = create_registry!(name: "cratesio")
    pkg = create_package!(registry, name: "serde")
    date = Date.new(2026, 9, 7)
    create_snapshot!(registry, taken_on: date, tracked: 10, provenant: 3)
    create_version!(pkg, number: "0.1.0", published_at: Time.utc(2025, 7, 3))
    unknown = create_version!(pkg, number: "0.2.0", published_at: nil)
    versions = Hanami.app["relations.package_versions"]
    snapshot = -> { operation.call(registry_name: "cratesio", taken_on: date) }

    expect { snapshot.call }.to raise_error(described_class::IncompleteObservation, /unchecked tracked versions/)
    versions.by_pk(unknown).command(:update).call(provenance_checked_at: Time.utc(2026, 9, 7))
    floor = create_version!(pkg, number: "0.3.0", published_at: Time.utc(2025, 7, 4))
    expect { snapshot.call }.to raise_error(described_class::IncompleteObservation, /unchecked tracked versions/)
    expect(Hanami.app["repos.adoption_snapshot_repo"].latest(registry.id))
      .to have_attributes(tracked_packages: 10, provenant_packages: 3)

    versions.by_pk(floor).command(:update).call(provenance_checked_at: Time.utc(2026, 9, 7))
    expect(snapshot.call.value!).to include(tracked_packages: 1, tracked_versions: 3, provenant_versions: 0)
  end

  it "fails cleanly for an unknown registry" do
    expect { operation.call(registry_name: "krates") }
      .to raise_error(ArgumentError, /registry krates is not seeded/)
  end
end
