# frozen_string_literal: true

RSpec.describe Ingestion::Adapters::Rubygems::Attestation do
  # Recorded live registry response (sigstore 0.2.3, a known
  # trusted-publishing release).
  let(:bundles) { json_fixture("v1_attestations_sigstore-0.2.3.json") }

  it "extracts the publisher identity from the Fulcio certificate" do
    provenance = described_class.parse(bundles)

    expect(provenance).to eq(
      provenance_kind: "sigstore_attestation",
      provenance_provider: "github",
      source_repository: "https://github.com/sigstore/sigstore-ruby",
      workflow_ref: "https://github.com/sigstore/sigstore-ruby/.github/workflows/release.yml@refs/tags/v0.2.3",
      commit_sha: "26ffbe0c1d6e16614fb9cd8b2ed40ab47d57d421",
      run_url: "https://github.com/sigstore/sigstore-ruby/actions/runs/22921869172/attempts/1",
      attestation_count: 1
    )
  end

  it "returns nil when no certificate is present" do
    expect(described_class.parse([{ "mediaType" => "x" }])).to be_nil
  end

  it "recovers identity from a later bundle when the first is malformed" do
    provenance = described_class.parse([{ "mediaType" => "x" }, bundles.first])

    expect(provenance).to include(
      source_repository: "https://github.com/sigstore/sigstore-ruby",
      attestation_count: 2
    )
  end

  it "is order-independent for multiple bundles" do
    doubled = [bundles.first, { "mediaType" => "x" }, bundles.first]

    expect(described_class.parse(doubled)).to eq(described_class.parse(doubled.reverse))
  end
end
