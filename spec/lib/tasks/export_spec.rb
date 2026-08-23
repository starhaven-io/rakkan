# frozen_string_literal: true

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
      restored = SQLite3::Database.new(":memory:")
      restored.execute("PRAGMA foreign_keys = ON")
      sql = File.read(export, encoding: "UTF-8")
      2.times { restored.execute_batch(sql) }

      expect(restored.get_first_value("PRAGMA foreign_key_check")).to be_nil
      expect(restored.get_first_value("SELECT generated_at FROM export_meta")).not_to be_nil
      expect(restored.get_first_row("SELECT name, display_name FROM registries")).to eq(%w[rubygems RubyGems.org])
      expect(restored.get_first_row("SELECT name, tracked, rank FROM packages")).to eq(["psych", 1, 1])
      expect(restored.get_first_row("SELECT number, provenance_kind FROM package_versions"))
        .to eq(["5.3.0", "sigstore_attestation"])
      expect(restored.get_first_row("SELECT taken_on, provenant_packages FROM adoption_snapshots"))
        .to eq(["2026-08-22", 1])
      expect(restored.get_first_value("SELECT COUNT(*) FROM package_versions")).to eq(1)
      expect(File.exist?("#{export}.tmp")).to be(false)
    ensure
      restored&.close
    end
  end
end
