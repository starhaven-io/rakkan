# frozen_string_literal: true

class FakeProvenanceAdapter
  def initialize(slug: "rubygems", responses: {})
    @slug = slug
    @responses = responses
  end

  def registry_slug = @slug

  def fetch_provenance(name:, number:, platform:)
    @responses.fetch("#{name}-#{number}-#{platform}", nil)
  end
end

RSpec.describe Ingestion::Operations::RefreshProvenance, :db do
  subject(:operation) { Ingestion::Slice["operations.refresh_provenance"] }

  let(:versions) { Hanami.app["relations.package_versions"] }
  let(:provenance) do
    { provenance_kind: "sigstore_attestation", provenance_provider: "github",
      source_repository: "https://github.com/ruby/psych", attestation_count: 1 }
  end

  it "records positive and negative checks and updates first_provenant_at" do
    registry = create_registry!
    pkg = create_package!(registry, name: "psych")
    attested = create_version!(pkg, number: "5.1.0", published_at: Time.utc(2026, 5, 1))
    plain = create_version!(pkg, number: "5.0.0", published_at: Time.utc(2026, 4, 1))
    adapter = FakeProvenanceAdapter.new(responses: { "psych-5.1.0-ruby" => provenance })

    result = operation.call(adapter:)

    expect(result).to be_success
    expect(result.value!).to eq(checked: 2, provenant: 1)
    expect(versions.by_pk(attested).one[:provenance_kind]).to eq("sigstore_attestation")
    expect(versions.by_pk(plain).one).to include(provenance_kind: nil)
    expect(versions.by_pk(plain).one[:provenance_checked_at]).not_to be_nil
    expect(Hanami.app["repos.package_repo"].find(registry.id, "psych").first_provenant_at.to_time)
      .to eq(Time.utc(2026, 5, 1))
  end

  it "clears stored provenance when the registry stops reporting it" do
    registry = create_registry!
    pkg = create_package!(registry, name: "psych", first_provenant_at: Time.utc(2026, 5, 1))
    stale = create_version!(pkg, number: "5.1.0", published_at: Time.utc(2026, 5, 1),
                                 provenance:, provenance_checked_at: Time.utc(2026, 1, 1))
    adapter = FakeProvenanceAdapter.new(responses: {}) # registry now reports nothing

    operation.call(stale_after: 3600, adapter:)

    row = versions.by_pk(stale).one
    expect(row).to include(provenance_kind: nil, provenance_provider: nil,
                           source_repository: nil, attestation_count: 0)
    expect(Hanami.app["repos.package_repo"].find(registry.id, "psych").first_provenant_at).to be_nil
  end

  it "only checks versions belonging to the adapter's registry" do
    create_registry!
    other = create_registry!(name: "cratesish")
    other_pkg = create_package!(other, name: "psych")
    other_version = create_version!(other_pkg, number: "1.0.0")
    adapter = FakeProvenanceAdapter.new(responses: {})

    result = operation.call(adapter:)

    expect(result.value!).to eq(checked: 0, provenant: 0)
    expect(versions.by_pk(other_version).one[:provenance_checked_at]).to be_nil
  end

  it "fails cleanly for an unknown registry" do
    result = operation.call(adapter: FakeProvenanceAdapter.new(slug: "krates"))

    expect(result.value!).to include(error: "unknown registry krates")
  end
end
