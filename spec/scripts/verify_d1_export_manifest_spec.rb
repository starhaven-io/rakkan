# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "tmpdir"

RSpec.describe "verify_d1_export_manifest.rb" do
  let(:script) { Hanami.app.root.join("scripts", "verify_d1_export_manifest.rb").to_s }

  def artifact(overrides = {})
    Dir.mktmpdir("rakkan-export-manifest") do |directory|
      export = File.join(directory, "d1_export.sql")
      manifest = File.join(directory, "d1_export.meta.json")
      File.write(export, "CREATE TABLE example (id INTEGER);\n")
      document = {
        "version" => 1,
        "database" => "rakkan",
        "generated_at" => "2026-09-08 02:24:05.052779",
        "schema_version" => 1,
        "counts" => {
          "registries" => 2,
          "packages" => 2_006,
          "package_versions" => 148_201,
          "adoption_snapshots" => 8
        },
        "export_sha256" => Digest::SHA256.file(export).hexdigest
      }.merge(overrides)
      File.write(manifest, JSON.generate(document))
      yield manifest, export, document
    end
  end

  it "validates the candidate identity, counts, and SQL checksum" do
    artifact do |manifest, export, document|
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, script, manifest, export)

      expect(status).to be_success
      expect(stderr).to be_empty
      expect(JSON.parse(stdout)).to eq(document)
    end
  end

  it "rejects SQL changed after the manifest was created" do
    artifact do |manifest, export, _document|
      File.write(export, "tampered\n")
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, script, manifest, export)

      expect(status).not_to be_success
      expect(stderr).to eq("D1 export checksum does not match the manifest\n")
    end
  end

  it "rejects missing artifacts without a backtrace" do
    artifact do |manifest, export, _document|
      File.unlink(manifest)
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, script, manifest, export)

      expect(status).not_to be_success
      expect(stderr).to include("invalid export artifact: No such file or directory")
      expect(stderr).not_to include("scripts/verify_d1_export_manifest.rb:")
    end
  end

  it "rejects symlinked artifacts" do
    artifact do |manifest, export, _document|
      target = "#{manifest}.target"
      File.rename(manifest, target)
      File.symlink(target, manifest)
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, script, manifest, export)

      expect(status).not_to be_success
      expect(stderr).to eq("export artifact must be regular and not a symlink: #{manifest}\n")
    end
  end

  it "rejects invalid generations, counts, and unexpected fields" do
    artifact("generated_at" => "2026-02-30 00:00:00.000000") do |manifest, export, _document|
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, script, manifest, export)
      expect(status).not_to be_success
      expect(stderr).to eq("export manifest has an invalid generation timestamp\n")
    end
    artifact("counts" => { "registries" => 2 }) do |manifest, export, _document|
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, script, manifest, export)
      expect(status).not_to be_success
      expect(stderr).to eq("export manifest must contain positive exact table counts\n")
    end
    artifact("unexpected" => true) do |manifest, export, _document|
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, script, manifest, export)
      expect(status).not_to be_success
      expect(stderr).to eq("export manifest has an unknown shape or version\n")
    end
  end
end
