# frozen_string_literal: true

RSpec.describe Ingestion::Adapters::Rubygems do
  subject(:adapter) do
    described_class.new(seed_dir: fixture_path("seed", "rubygems"), http_client: client)
  end

  let(:client) { FixtureHelpers::FakeHTTPClient.new(responses) }
  let(:responses) { {} }

  describe "seed streaming" do
    it "yields tracked packages with real ranks" do
      packages = adapter.each_tracked_package.to_a

      expect(packages.map { |p| p[:name] }).to contain_exactly("psych", "rack", "logger")
      psych = packages.find { |p| p[:name] == "psych" }
      expect(psych).to include(rank: Integer, downloads_total: Integer, registry_ref: String)
    end

    it "yields versions keyed to their package" do
      versions = adapter.each_seed_version.to_a

      expect(versions.size).to eq(18)
      expect(versions.first.keys).to contain_exactly(
        :registry_ref, :package_ref, :number, :platform,
        :published_at, :prerelease, :latest, :yanked
      )
      expect(versions.map { |v| v[:published_at] }).to all(be_a(Time))
    end

    it "parses seed attestations into provenance hashes" do
      attestations = adapter.each_seed_attestation.to_a

      expect(attestations).not_to be_empty
      attestations.each do |att|
        expect(att[:version_ref]).to match(/\A\d+\z/)
        expect(att[:provenance]).to include(
          provenance_kind: "sigstore_attestation",
          provenance_provider: "github"
        )
        expect(att[:provenance][:attestation_count]).to be >= 1
      end
    end

    it "reports when the seed data was authoritative" do
      expect(adapter.seed_as_of).to eq(Time.utc(2026, 8, 10, 21, 21, 1))
    end
  end

  describe "#fetch_provenance" do
    let(:responses) do
      {
        "https://rubygems.org/api/v1/attestations/sigstore-0.2.3.json" =>
          json_fixture("v1_attestations_sigstore-0.2.3.json"),
        "https://rubygems.org/api/v1/attestations/rack-3.2.7.json" =>
          json_fixture("v1_attestations_rack-3.2.7.json")
      }
    end

    it "parses provenance for an attested version" do
      provenance = adapter.fetch_provenance(name: "sigstore", number: "0.2.3", platform: "ruby")

      expect(provenance).to include(
        provenance_kind: "sigstore_attestation",
        source_repository: "https://github.com/sigstore/sigstore-ruby"
      )
    end

    it "returns nil when the registry reports no attestations" do
      expect(adapter.fetch_provenance(name: "rack", number: "3.2.7", platform: "ruby")).to be_nil
    end

    it "appends the platform for non-ruby versions" do
      responses["https://rubygems.org/api/v1/attestations/psych-5.4.0-java.json"] = []

      adapter.fetch_provenance(name: "psych", number: "5.4.0", platform: "java")

      expect(client.requests.last).to end_with("psych-5.4.0-java.json")
    end

    it "bypasses the read cache so checks observe current state" do
      adapter.fetch_provenance(name: "rack", number: "3.2.7", platform: "ruby")

      expect(client.ttls.last).to eq(0)
    end
  end

  describe "#new_versions" do
    let(:from) { Time.utc(2026, 8, 12) }
    let(:to) { Time.utc(2026, 8, 13) }
    let(:base) { "https://rubygems.org/api/v1/timeframe_versions.json" }
    let(:responses) do
      {
        "#{base}?from=#{from.iso8601}&to=#{to.iso8601}&page=1" =>
          json_fixture("v1_timeframe_versions_sample.json"),
        "#{base}?from=#{from.iso8601}&to=#{to.iso8601}&page=2" => []
      }
    end

    it "pages until the registry returns an empty batch" do
      result = adapter.new_versions(from:, to:, max_pages: 10)

      expect(client.requests.size).to eq(2)
      expect(result[:drained]).to be(true)
      expect(result[:pages]).to eq(2)
      expect(result[:entries].size).to eq(30)
      expect(result[:entries].first.keys).to contain_exactly(
        :package_name, :number, :platform, :published_at, :prerelease, :yanked
      )
    end

    it "reports drained: false when the page budget runs out on a full page" do
      result = adapter.new_versions(from:, to:, max_pages: 1)

      expect(client.requests.size).to eq(1)
      expect(result[:drained]).to be(false)
      expect(result[:entries].size).to eq(30)
    end
  end
end
