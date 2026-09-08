# frozen_string_literal: true

require "digest"
require "json"
require "rake"
require "sqlite3"
require "tmpdir"

RSpec.describe "export rake tasks", :db do
  before(:all) do
    Rake.application.rake_require("tasks/export", [Hanami.app.root.join("lib").to_s])
  end

  before do
    Rake::Task["export:d1"].reenable
  end

  it "writes a complete D1 database that can be restored by SQLite" do
    registry = create_registry!
    package = create_package!(registry, name: "psych", first_provenant_at: Time.utc(2026, 8, 1))
    create_version!(
      package,
      number: "5.3.0",
      published_at: Time.utc(2026, 8, 1),
      provenance: { provenance_kind: "sigstore_attestation", attestation_count: 1 }
    )
    create_snapshot!(registry, taken_on: Date.new(2026, 8, 22), tracked: 1, provenant: 1,
                               tracked_versions: 1, provenant_versions: 1)

    Dir.mktmpdir("rakkan-d1-export") do |dir|
      FileUtils.mkdir_p(File.join(dir, "db"))
      allow(Hanami.app).to receive(:root).and_return(Pathname(dir))

      expect { Rake::Task["export:d1"].invoke }
        .to output(/wrote .*d1_export\.sql \(registries: 1, packages: 1, package_versions: 1, adoption_snapshots: 1\)/)
        .to_stdout

      export = File.join(dir, "db", "d1_export.sql")
      metadata = File.join(dir, "db", "d1_export.meta.json")
      manifest = JSON.parse(File.read(metadata, encoding: "UTF-8"))
      restored = SQLite3::Database.new(":memory:")
      restored.execute("PRAGMA foreign_keys = ON")
      sql = File.read(export, encoding: "UTF-8")
      expect(manifest).to include(
        "version" => 1,
        "database" => "rakkan",
        "schema_version" => 1,
        "counts" => {
          "registries" => 1,
          "packages" => 1,
          "package_versions" => 1,
          "adoption_snapshots" => 1
        },
        "export_sha256" => Digest::SHA256.file(export).hexdigest
      )
      expect(manifest.keys.sort)
        .to eq(%w[counts database export_sha256 generated_at schema_version version])
      expect(manifest.fetch("generated_at")).to match(/\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{6}\z/)
      expect(sql.index("CREATE TABLE export_meta")).to be > sql.rindex("INSERT INTO adoption_snapshots")
      marker_lines = sql.lines.last(2)
      expect(marker_lines.fetch(0))
        .to eq("CREATE TABLE export_meta (generated_at timestamp NOT NULL, schema_version integer NOT NULL);\n")
      expect(marker_lines.fetch(1))
        .to eq("INSERT INTO export_meta (generated_at, schema_version) " \
               "VALUES ('#{manifest.fetch("generated_at")}', #{manifest.fetch("schema_version")});\n")
      2.times { restored.execute_batch(sql) }

      expect(restored.get_first_value("PRAGMA foreign_key_check")).to be_nil
      expect(restored.get_first_value("SELECT generated_at FROM export_meta")).to eq(manifest.fetch("generated_at"))
      expect(restored.get_first_value("SELECT schema_version FROM export_meta")).to eq(1)
      expect(restored.get_first_row("SELECT name, display_name FROM registries")).to eq(%w[rubygems RubyGems.org])
      expect(restored.get_first_row("SELECT name, tracked, rank FROM packages")).to eq(["psych", 1, 1])
      expect(restored.get_first_row("SELECT number, provenance_kind FROM package_versions"))
        .to eq(["5.3.0", "sigstore_attestation"])
      expect(restored.get_first_row("SELECT taken_on, provenant_packages FROM adoption_snapshots"))
        .to eq(["2026-08-22", 1])
      expect(restored.get_first_value("SELECT COUNT(*) FROM package_versions")).to eq(1)
      expect(File.exist?("#{export}.tmp")).to be(false)
      expect(File.exist?("#{metadata}.tmp")).to be(false)
    ensure
      restored&.close
    end
  end

  it "rejects a non-integer schema contract version" do
    contract = Hanami.app.root.join("site", "schema-contract.json").to_s
    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:read).with(contract, encoding: "UTF-8")
                                 .and_return('{"version":1.5,"compatibleVersions":[1]}')

    expect { Rake::Task["export:d1"].invoke }
      .to raise_error(ArgumentError, "site schema contract version must be a positive integer")
  end

  it "rejects an invalid schema compatibility set" do
    contract = Hanami.app.root.join("site", "schema-contract.json").to_s
    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:read).with(contract, encoding: "UTF-8")
                                 .and_return('{"version":1,"compatibleVersions":[2,2]}')

    expect { Rake::Task["export:d1"].invoke }
      .to raise_error(
        ArgumentError,
        "site schema compatible versions must be unique positive integers including the export version"
      )
  end
end
