# frozen_string_literal: true

require "tmpdir"
require "zlib"

RSpec.describe Ingestion::Adapters::Cratesio do
  subject(:adapter) do
    described_class.new(seed_dir: fixture_path("seed", "cratesio"), http_client: client)
  end

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

  # The daily dump is this registry's discovery path, so re-seeding replaces
  # a live feed walk and new_versions stays unimplemented on purpose.
  it "does not implement live discovery" do
    expect { adapter.new_versions(from: Time.now, to: Time.now, max_pages: 1) }
      .to raise_error(NotImplementedError)
  end

  describe "seed streaming" do
    it "yields tracked crates in rank order" do
      packages = adapter.each_tracked_package.to_a

      expect(packages.map { |p| p[:name] }).to eq(%w[serde rand cargo-semver-checks])
      expect(packages.first).to eq(
        name: "serde", registry_ref: "1", rank: 1, downloads_total: 405_686_799
      )
    end

    it "yields versions keyed to their crate, with no platform dimension" do
      versions = adapter.each_seed_version.to_a

      expect(versions.size).to eq(8)
      expect(versions.map { |v| v[:platform] }).to all(eq(""))
      expect(versions.map { |v| v[:published_at] }).to all(be_a(Time))
      expect(versions.find { |v| v[:number] == "0.45.0-rc.1" }).to include(
        registry_ref: "3002", package_ref: "3", prerelease: true, latest: false, yanked: true
      )
      # The dump renders created_at as a Postgres timestamptz: fractional
      # seconds and its own +00 offset, not a naive local timestamp.
      expect(versions.find { |v| v[:number] == "1.0.228" }).to include(
        prerelease: false, latest: true, yanked: false,
        published_at: Time.utc(2025, 9, 27, 16, 51, 35, 111_111)
      )
    end

    # The dump exports no trustpub_data, so seeding must not leave behind an
    # observation that a version was checked and found unattested.
    it "yields no attestations and reports no provenance authority" do
      expect(adapter.each_seed_attestation.to_a).to be_empty
      # The dump stamps nanoseconds; parsing must not round them away.
      expect(adapter.seed_as_of).to eq(Time.utc(2026, 8, 20, 2, 0, 21, Rational(810_126_238, 1000)))
      expect(adapter.provenance_seed_as_of).to be_nil
    end

    it "floors provenance checks at the trustpub_data migration" do
      expect(adapter.provenance_available_since).to eq(Time.utc(2025, 7, 4))
    end

    # A naive timestamp would be read in the host's zone, so seeds built on
    # two machines would disagree. Refuse it rather than guess.
    it "refuses a seed timestamp with no UTC offset" do
      Dir.mktmpdir do |dir|
        Zlib::GzipWriter.open(File.join(dir, "tracked_versions.tsv.gz")) do |gz|
          gz.puts %w[id number crate_id created_at prerelease latest yanked].join("\t")
          gz.puts ["1", "1.0.0", "7", "2026-02-02 08:00:00", "false", "true", "false"].join("\t")
        end
        naive = described_class.new(seed_dir: dir, http_client: client)

        expect { naive.each_seed_version.to_a }
          .to raise_error(ArgumentError, /lacks a UTC offset/)
      end
    end
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

  # The GitLab variant names its fields project_path and job_id, not
  # repository and run_id; only sha is shared with the GitHub variant.
  it "maps a GitLab publisher from its own field names" do
    url = "https://crates.io/api/v1/crates/example/1.0.0"
    responses[url] = {
      "version" => {
        "trustpub_data" => {
          "provider" => "gitlab",
          "project_path" => "rust-lang/cargo",
          "job_id" => "9876543210",
          "sha" => "abc123"
        }
      }
    }

    provenance = adapter.fetch_provenance(name: "example", number: "1.0.0", platform: "rust")

    expect(provenance).to eq(
      provenance_kind: "trustpub_metadata",
      provenance_provider: "gitlab",
      source_repository: "https://gitlab.com/rust-lang/cargo",
      workflow_ref: nil,
      commit_sha: "abc123",
      run_url: "https://gitlab.com/rust-lang/cargo/-/jobs/9876543210",
      attestation_count: 1
    )
  end

  # A provider variant added after this adapter shipped still records that the
  # version was trusted-published, without inventing a repository for it.
  it "records an unrecognized provider without inventing an identity" do
    url = "https://crates.io/api/v1/crates/example/1.0.0"
    responses[url] = {
      "version" => {
        "trustpub_data" => { "provider" => "circleci", "project_slug" => "gh/example", "sha" => "def456" }
      }
    }

    provenance = adapter.fetch_provenance(name: "example", number: "1.0.0", platform: "rust")

    expect(provenance).to include(
      provenance_kind: "trustpub_metadata",
      provenance_provider: "circleci",
      source_repository: nil,
      run_url: nil,
      commit_sha: "def456"
    )
  end

  it "returns nil for unstable trusted-publishing metadata shapes" do
    url = "https://crates.io/api/v1/crates/example/1.0.0"

    ["unexpected", {}, { "repository" => "owner/example" }].each do |trustpub_data|
      responses[url] = { "version" => { "trustpub_data" => trustpub_data } }

      expect(adapter.fetch_provenance(name: "example", number: "1.0.0", platform: "rust")).to be_nil
    end
  end
end
