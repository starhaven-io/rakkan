# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "tmpdir"

RSpec.describe "verify_d1_recovery_manifest.rb" do
  let(:script) { Hanami.app.root.join("scripts", "verify_d1_recovery_manifest.rb").to_s }

  def artifact(overrides = {})
    Dir.mktmpdir("rakkan-recovery-manifest") do |directory|
      backup = File.join(directory, "backup.sql")
      manifest = File.join(directory, "manifest.json")
      File.write(backup, "this intentionally need not be replayable SQL\n")
      document = {
        "version" => 1,
        "database" => "rakkan",
        "created_at" => "2026-09-07T01:02:03Z",
        "bookmark" => "01234567-89abcdef-01234567-89abcdef0123456789abcdef01234567",
        "schema_version" => 1,
        "generated_at" => "2026-09-07 01:01:59.123456",
        "counts" => {
          "registries" => 2,
          "packages" => 2_000,
          "package_versions" => 12_000,
          "adoption_snapshots" => 10
        },
        "backup_sha256" => Digest::SHA256.file(backup).hexdigest
      }.merge(overrides)
      File.write(manifest, JSON.generate(document))
      yield manifest, backup, document
    end
  end

  it "validates metadata and checksum without requiring the SQL evidence to replay" do
    artifact do |manifest, backup, document|
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, script, manifest, backup)

      expect(status).to be_success
      expect(stderr).to be_empty
      expect(JSON.parse(stdout)).to eq(document)
    end
  end

  it "rejects a backup changed after the manifest was created" do
    artifact do |manifest, backup, _document|
      File.write(backup, "tampered\n")
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, script, manifest, backup)

      expect(status).not_to be_success
      expect(stderr).to include("checksum")
    end
  end

  it "rejects incomplete count evidence and unexpected fields" do
    artifact("counts" => { "registries" => 1 }) do |manifest, backup, _document|
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, script, manifest, backup)
      expect(status).not_to be_success
      expect(stderr).to eq("recovery manifest must contain positive exact table counts\n")
      expect(stderr).not_to include("NameError", "scripts/verify_d1_recovery_manifest.rb:")
    end
    artifact("unexpected" => true) do |manifest, backup, _document|
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, script, manifest, backup)
      expect(status).not_to be_success
      expect(stderr).to eq("recovery manifest has an unknown shape or version\n")
    end
  end

  it "reports an invalid, calendar-impossible, or noncanonical creation time without a backtrace" do
    ["not-a-time", "2026-02-30T00:00:00Z", "2026-09-07T01:02:03+00:00", 42].each do |created_at|
      artifact("created_at" => created_at) do |manifest, backup, _document|
        _stdout, stderr, status = Open3.capture3(RbConfig.ruby, script, manifest, backup)

        expect(status).not_to be_success
        expect(stderr).to eq("recovery manifest has a noncanonical UTC creation time\n")
      end
    end
  end

  it "rejects a syntactically shaped but impossible export generation timestamp" do
    ["2026-99-99 99:99:99", "2026-02-30 00:00:00", "2026-04-31 12:00:00"].each do |generated_at|
      artifact("generated_at" => generated_at) do |manifest, backup, _document|
        _stdout, stderr, status = Open3.capture3(RbConfig.ruby, script, manifest, backup)

        expect(status).not_to be_success
        expect(stderr).to eq("recovery manifest has an invalid export generation timestamp\n")
      end
    end
  end
end
