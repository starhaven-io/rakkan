# frozen_string_literal: true

class FakeProvenanceAdapter < Ingestion::Adapters::RegistryAdapter
  attr_reader :requested, :provenance_available_since

  def initialize(slug: "rubygems", responses: {}, provenance_available_since: nil)
    super()
    @slug = slug
    @responses = responses
    @provenance_available_since = provenance_available_since
    @requested = []
  end

  def registry_slug = @slug

  def fetch_provenance(name:, number:, platform:)
    key = "#{name}-#{number}-#{platform}"
    @requested << key
    @responses.fetch(key, nil)
  end
end

RSpec.describe Ingestion::Operations::RefreshProvenance, :db do
  subject(:operation) { Ingestion::Slice["operations.refresh_provenance"] }

  let(:versions) { Hanami.app["relations.package_versions"] }
  let(:provenance) do
    { provenance_kind: "sigstore_attestation", provenance_provider: "github",
      source_repository: "https://github.com/ruby/psych", attestation_count: 1 }
  end

  it "provides a per-version default for adapters that cannot batch" do
    adapter = FakeProvenanceAdapter.new(responses: { "psych-5.1.0-ruby" => provenance })
    versions = [{ number: "5.1.0", platform: "ruby" }]

    results = adapter.each_provenance(name: "psych", versions:).to_a

    expect(results).to eq([[versions.first, provenance]])
    expect(adapter.requested).to eq(["psych-5.1.0-ruby"])
  end

  it "lets crates.io satisfy each package batch with one request" do
    registry = create_registry!(name: "cratesio")
    cargo = create_package!(registry, name: "cargo-semver-checks")
    serde = create_package!(registry, name: "serde", rank: 2)
    create_version!(cargo, number: "0.50.0", platform: "", published_at: Time.utc(2026, 8, 1))
    create_version!(cargo, number: "0.43.0", platform: "", published_at: Time.utc(2026, 7, 1))
    create_version!(serde, number: "1.0.228", platform: "", published_at: Time.utc(2026, 6, 1))
    cargo_url = "https://crates.io/api/v1/crates/cargo-semver-checks/versions"
    serde_url = "https://crates.io/api/v1/crates/serde/versions"
    client = FixtureHelpers::FakeHTTPClient.new(
      cargo_url => json_fixture("cratesio_versions.json"),
      serde_url => { "versions" => [json_fixture("cratesio_version_token.json").fetch("version")] }
    )
    adapter = Ingestion::Adapters::Cratesio.new(
      seed_dir: fixture_path("seed", "cratesio"), http_client: client
    )

    result = operation.call(limit: 3, adapter:)

    expect(result.value!).to eq(checked: 3, provenant: 1, settled: 0, remaining: 0)
    expect(client.requests).to eq([cargo_url, serde_url])
  end

  it "falls back for an omitted version and continues with the next crate" do
    registry = create_registry!(name: "cratesio")
    cargo = create_package!(registry, name: "cargo-semver-checks")
    serde = create_package!(registry, name: "serde", rank: 2)
    cargo_trusted = create_version!(
      cargo, number: "0.50.0", platform: "", published_at: Time.utc(2026, 8, 3)
    )
    cargo_omitted = create_version!(
      cargo, number: "0.43.0", platform: "", published_at: Time.utc(2026, 8, 2)
    )
    serde_plain = create_version!(
      serde, number: "1.0.228", platform: "", published_at: Time.utc(2026, 8, 1)
    )
    cargo_url = "https://crates.io/api/v1/crates/cargo-semver-checks/versions"
    omitted_url = "https://crates.io/api/v1/crates/cargo-semver-checks/0.43.0"
    serde_url = "https://crates.io/api/v1/crates/serde/versions"
    cargo_response = json_fixture("cratesio_versions.json")
    cargo_response["versions"] = cargo_response.fetch("versions").first(1)
    client = FixtureHelpers::FakeHTTPClient.new(
      cargo_url => cargo_response,
      omitted_url => nil,
      serde_url => { "versions" => [json_fixture("cratesio_version_token.json").fetch("version")] }
    )
    adapter = Ingestion::Adapters::Cratesio.new(
      seed_dir: fixture_path("seed", "cratesio"), http_client: client
    )

    result = operation.call(limit: 3, adapter:)

    expect(result.value!).to eq(checked: 3, provenant: 1, settled: 0, remaining: 0)
    expect(client.requests).to eq([cargo_url, omitted_url, serde_url])
    expect([cargo_trusted, cargo_omitted, serde_plain]).to all(
      satisfy { |id| versions.by_pk(id).one[:provenance_checked_at] }
    )
  end

  it "keeps a completed crate batch when a later crate request is interrupted" do
    registry = create_registry!(name: "cratesio")
    cargo = create_package!(registry, name: "cargo-semver-checks")
    serde = create_package!(registry, name: "serde", rank: 2)
    completed = create_version!(
      cargo, number: "0.50.0", platform: "", published_at: Time.utc(2026, 8, 2)
    )
    interrupted = create_version!(
      serde, number: "1.0.228", platform: "", published_at: Time.utc(2026, 8, 1)
    )
    cargo_url = "https://crates.io/api/v1/crates/cargo-semver-checks/versions"
    serde_url = "https://crates.io/api/v1/crates/serde/versions"
    client = FixtureHelpers::FakeHTTPClient.new(cargo_url => json_fixture("cratesio_versions.json"))
    allow(client).to receive(:get_json).and_wrap_original do |method, url, **kwargs|
      raise Net::ReadTimeout, "timed out" if url == serde_url

      method.call(url, **kwargs)
    end
    adapter = Ingestion::Adapters::Cratesio.new(
      seed_dir: fixture_path("seed", "cratesio"), http_client: client
    )

    expect { operation.call(limit: 2, adapter:) }.to raise_error(Net::ReadTimeout)

    expect(versions.by_pk(completed).one[:provenance_checked_at]).not_to be_nil
    expect(versions.by_pk(interrupted).one[:provenance_checked_at]).to be_nil
  end

  it "records positive and negative checks and updates first_provenant_at" do
    registry = create_registry!
    pkg = create_package!(registry, name: "psych")
    attested = create_version!(pkg, number: "5.1.0", published_at: Time.utc(2026, 5, 1))
    plain = create_version!(pkg, number: "5.0.0", published_at: Time.utc(2026, 4, 1))
    adapter = FakeProvenanceAdapter.new(responses: { "psych-5.1.0-ruby" => provenance })

    result = operation.call(adapter:)

    expect(result).to be_success
    expect(result.value!).to eq(checked: 2, provenant: 1, settled: 0, remaining: 0)
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

    expect(result.value!).to eq(checked: 0, provenant: 0, settled: 0, remaining: 0)
    expect(versions.by_pk(other_version).one[:provenance_checked_at]).to be_nil
  end

  it "settles versions predating the registry's provenance support without asking it" do
    registry = create_registry!
    pkg = create_package!(registry, name: "serde")
    old = create_version!(pkg, number: "1.0.197", published_at: Time.utc(2024, 3, 1))
    recent = create_version!(pkg, number: "1.0.228", published_at: Time.utc(2025, 9, 27))
    unknown = create_version!(pkg, number: "0.0.1", published_at: nil)
    adapter = FakeProvenanceAdapter.new(provenance_available_since: Time.utc(2025, 7, 4))

    result = operation.call(adapter:)

    expect(result.value!).to eq(checked: 2, provenant: 0, settled: 1, remaining: 0)
    # The old version is recorded as observed, not left unchecked, but no
    # request was spent on it. An unknown publish time still gets asked.
    expect(versions.by_pk(old).one[:provenance_checked_at]).not_to be_nil
    expect(adapter.requested).to contain_exactly("serde-1.0.228-ruby", "serde-0.0.1-ruby")
    expect(versions.by_pk(recent).one[:provenance_checked_at]).not_to be_nil
    expect(versions.by_pk(unknown).one[:provenance_checked_at]).not_to be_nil
  end

  it "checks a newest-first bounded batch and resumes with the next version" do
    registry = create_registry!
    pkg = create_package!(registry, name: "serde")
    oldest = create_version!(pkg, number: "1.0.0", published_at: Time.utc(2025, 7, 5))
    create_version!(pkg, number: "2.0.0", published_at: Time.utc(2025, 8, 5))
    create_version!(pkg, number: "3.0.0", published_at: Time.utc(2025, 9, 5))
    adapter = FakeProvenanceAdapter.new(provenance_available_since: Time.utc(2025, 7, 4))

    first = operation.call(limit: 2, adapter:)

    expect(first.value!).to eq(checked: 2, provenant: 0, settled: 0, remaining: 1)
    expect(adapter.requested).to eq(%w[serde-3.0.0-ruby serde-2.0.0-ruby])
    expect(versions.by_pk(oldest).one[:provenance_checked_at]).to be_nil

    second = operation.call(limit: 2, adapter:)

    expect(second.value!).to eq(checked: 1, provenant: 0, settled: 0, remaining: 0)
    expect(adapter.requested).to eq(%w[serde-3.0.0-ruby serde-2.0.0-ruby serde-1.0.0-ruby])
    expect(versions.by_pk(oldest).one[:provenance_checked_at]).not_to be_nil
  end

  it "keeps completed checks when a later request interrupts the batch" do
    registry = create_registry!
    pkg = create_package!(registry, name: "serde")
    interrupted = create_version!(pkg, number: "2.0.0", published_at: Time.utc(2025, 8, 5))
    completed = create_version!(pkg, number: "3.0.0", published_at: Time.utc(2025, 9, 5))
    adapter = FakeProvenanceAdapter.new(provenance_available_since: Time.utc(2025, 7, 4))
    allow(adapter).to receive(:fetch_provenance).and_wrap_original do |method, **args|
      raise Net::ReadTimeout, "timed out" if args[:number] == "2.0.0"

      method.call(**args)
    end

    expect { operation.call(limit: 2, adapter:) }.to raise_error(Net::ReadTimeout)

    expect(versions.by_pk(completed).one[:provenance_checked_at]).not_to be_nil
    expect(versions.by_pk(interrupted).one[:provenance_checked_at]).to be_nil

    allow(adapter).to receive(:fetch_provenance).and_call_original
    result = operation.call(limit: 2, adapter:)

    expect(result.value!).to eq(checked: 1, provenant: 0, settled: 0, remaining: 0)
    expect(versions.by_pk(interrupted).one[:provenance_checked_at]).not_to be_nil
  end

  it "fails cleanly for an unknown registry" do
    result = operation.call(adapter: FakeProvenanceAdapter.new(slug: "krates"))

    expect(result.value!).to include(error: "unknown registry krates")
  end
end
