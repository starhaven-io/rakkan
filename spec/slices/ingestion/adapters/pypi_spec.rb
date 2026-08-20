# frozen_string_literal: true

RSpec.describe Ingestion::Adapters::Pypi do
  subject(:adapter) { described_class.new(http_client: client) }

  let(:release_url) { "https://pypi.org/pypi/sampleproject/4.0.0/json" }
  let(:wheel_url) do
    "https://pypi.org/integrity/sampleproject/4.0.0/" \
      "sampleproject-4.0.0-py3-none-any.whl/provenance"
  end
  let(:sdist_url) do
    "https://pypi.org/integrity/sampleproject/4.0.0/" \
      "sampleproject-4.0.0.tar.gz/provenance"
  end
  let(:client) { FixtureHelpers::FakeHTTPClient.new(responses) }
  let(:responses) do
    {
      release_url => json_fixture("pypi_release_sampleproject-4.0.0.json"),
      wheel_url => json_fixture("pypi_provenance_sampleproject.json"),
      sdist_url => json_fixture("pypi_provenance_sampleproject.json")
    }
  end

  it "identifies the registry" do
    expect(adapter).to have_attributes(
      registry_slug: "pypi",
      display_name: "PyPI",
      registry_url: "https://pypi.org"
    )
  end

  it "does not implement the bulk seed and discovery surface" do
    %i[each_tracked_package each_seed_version each_seed_attestation].each do |method|
      expect { adapter.public_send(method) }.to raise_error(NotImplementedError)
    end
    expect { adapter.new_versions(from: Time.now, to: Time.now, max_pages: 1) }
      .to raise_error(NotImplementedError)
  end

  it "aggregates per-file trusted publisher provenance for a release" do
    provenance = adapter.fetch_provenance(name: "sampleproject", number: "4.0.0", platform: "python")

    expect(provenance).to eq(
      provenance_kind: "digital_attestation",
      provenance_provider: "github",
      source_repository: "https://github.com/pypa/sampleproject",
      workflow_ref: "release.yml",
      commit_sha: nil,
      run_url: nil,
      attestation_count: 2
    )
    expect(client.accepts).to eq(
      ["application/json", "application/vnd.pypi.integrity.v1+json",
       "application/vnd.pypi.integrity.v1+json"]
    )
    expect(client.ttls).to eq([3600, 0, 0])
  end

  it "returns nil when no distribution file has provenance" do
    responses[wheel_url] = nil
    responses[sdist_url] = nil

    provenance = adapter.fetch_provenance(name: "sampleproject", number: "4.0.0", platform: "python")

    expect(provenance).to be_nil
  end
end
