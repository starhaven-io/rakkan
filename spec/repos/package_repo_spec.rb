# frozen_string_literal: true

RSpec.describe Rakkan::Repos::PackageRepo, :db do
  subject(:repo) { Hanami.app["repos.package_repo"] }

  let(:registry) { create_registry! }

  describe "#find" do
    it "returns the package struct or nil" do
      create_package!(registry, name: "rack")

      expect(repo.find(registry.id, "rack")).to have_attributes(name: "rack")
      expect(repo.find(registry.id, "nope")).to be_nil
    end
  end

  describe "#search" do
    before do
      create_package!(registry, name: "rack", rank: 1, downloads: 300)
      create_package!(registry, name: "rack-test", rank: 2, downloads: 200)
      create_package!(registry, name: "racket", rank: 3, downloads: 100)
      create_package!(registry, name: "psych", rank: 4, downloads: 50)
    end

    it "matches substrings ordered by downloads" do
      expect(repo.search(registry.id, "rack").map(&:name)).to eq(%w[rack rack-test racket])
    end

    it "does not treat LIKE metacharacters as wildcards" do
      expect(repo.search(registry.id, "rack%")).to be_empty
      expect(repo.search(registry.id, "_")).to be_empty
    end
  end

  describe "#recent_conversions" do
    it "orders provenant packages by newest first provenance" do
      create_package!(registry, name: "old", first_provenant_at: Time.utc(2025, 1, 1))
      create_package!(registry, name: "new", first_provenant_at: Time.utc(2026, 6, 1))
      create_package!(registry, name: "never")

      expect(repo.recent_conversions(registry.id).map(&:name)).to eq(%w[new old])
    end
  end

  describe "#versions_of" do
    it "returns versions newest first with provenance predicates" do
      pkg = create_package!(registry, name: "psych")
      create_version!(pkg, number: "5.0.0", published_at: Time.utc(2023, 1, 1))
      create_version!(pkg, number: "5.1.0", published_at: Time.utc(2024, 1, 1),
                           provenance: { provenance_kind: "sigstore_attestation", attestation_count: 1 })

      versions = repo.versions_of(pkg.id)

      expect(versions.map(&:number)).to eq(%w[5.1.0 5.0.0])
      expect(versions.map(&:provenant?)).to eq([true, false])
    end
  end
end
