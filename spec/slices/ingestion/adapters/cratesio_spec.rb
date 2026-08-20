# frozen_string_literal: true

RSpec.describe Ingestion::Adapters::Cratesio do
  subject(:adapter) { described_class.new(http_client: client) }

  let(:client) { FixtureHelpers::FakeHTTPClient.new(responses) }
  let(:responses) do
    {
      "https://crates.io/api/v1/crates/cargo-semver-checks/0.50.0" =>
        json_fixture("cratesio_version_trusted.json"),
      "https://crates.io/api/v1/crates/serde/1.0.228" =>
        json_fixture("cratesio_version_token.json")
    }
  end

  it "identifies the registry" do
    expect(adapter).to have_attributes(
      registry_slug: "cratesio",
      display_name: "crates.io",
      registry_url: "https://crates.io"
    )
  end

  it "does not implement the bulk seed and discovery surface" do
    %i[each_tracked_package each_seed_version each_seed_attestation].each do |method|
      expect { adapter.public_send(method) }.to raise_error(NotImplementedError)
    end
    expect { adapter.new_versions(from: Time.now, to: Time.now, max_pages: 1) }
      .to raise_error(NotImplementedError)
  end

  it "maps trusted publishing metadata to shared provenance columns" do
    provenance = adapter.fetch_provenance(
      name: "cargo-semver-checks", number: "0.50.0", platform: "rust"
    )

    expect(provenance).to eq(
      provenance_kind: "trustpub_metadata",
      provenance_provider: "github",
      source_repository: "https://github.com/obi1kenobi/cargo-semver-checks",
      workflow_ref: nil,
      commit_sha: "4297e8b5f6306531375ba2ba332171e5792b4c38",
      run_url: "https://github.com/obi1kenobi/cargo-semver-checks/actions/runs/30708975727",
      attestation_count: 1
    )
    expect(client.ttls.last).to eq(0)
  end

  it "returns nil for a version published with a regular token" do
    provenance = adapter.fetch_provenance(name: "serde", number: "1.0.228", platform: "rust")

    expect(provenance).to be_nil
  end

  it "returns nil for unstable trusted-publishing metadata shapes" do
    url = "https://crates.io/api/v1/crates/example/1.0.0"

    ["unexpected", {}, { "repository" => "owner/example" }].each do |trustpub_data|
      responses[url] = { "version" => { "trustpub_data" => trustpub_data } }

      expect(adapter.fetch_provenance(name: "example", number: "1.0.0", platform: "rust")).to be_nil
    end
  end
end
