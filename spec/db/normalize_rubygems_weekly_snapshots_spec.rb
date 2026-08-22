# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"

RSpec.describe "RubyGems weekly snapshot normalization" do
  it "normalizes Monday and Sunday boundaries, keeps the latest scan, and is idempotent" do
    Dir.mktmpdir do |dir|
      database = File.join(dir, "rakkan.sqlite")
      sqlite(database, Hanami.app.root.join("config", "db", "structure.sql").read)
      sqlite(database, seed_sql)

      first_pass = nil
      2.times do
        normalize(database)

        current = sqlite(database, "SELECT * FROM adoption_snapshots ORDER BY id;")
        expect(current).to eq(first_pass) if first_pass
        first_pass = current
      end

      rows = JSON.parse(sqlite(database, result_query, "-json"))
      expect(rows).to eq([
                           { "registry" => "rubygems", "taken_on" => "2026-08-03",
                             "provenant_packages" => 95, "provenant_versions" => 665 },
                           { "registry" => "rubygems", "taken_on" => "2026-08-10",
                             "provenant_packages" => 96, "provenant_versions" => 666 },
                           { "registry" => "rubygems", "taken_on" => "2026-08-17",
                             "provenant_packages" => 98, "provenant_versions" => 668 },
                           { "registry" => "pypi", "taken_on" => "2026-08-21",
                             "provenant_packages" => 12, "provenant_versions" => 50 }
                         ])
    end
  end

  it "allows a prepared database with no snapshots yet" do
    Dir.mktmpdir do |dir|
      database = File.join(dir, "rakkan.sqlite")
      sqlite(database, Hanami.app.root.join("config", "db", "structure.sql").read)

      normalize(database)

      expect(sqlite(database, "SELECT COUNT(*) FROM adoption_snapshots;").strip).to eq("0")
    end
  end

  def normalize(database)
    _stdout, stderr, status = Open3.capture3(
      "bash", Hanami.app.root.join("scripts", "normalize-rubygems-weekly-snapshots.sh").to_s,
      database
    )
    expect(status).to be_success, stderr
  end

  def sqlite(database, sql, output_mode = nil)
    command = ["sqlite3"]
    command << output_mode if output_mode
    command << database
    stdout, stderr, status = Open3.capture3(*command, stdin_data: sql)
    expect(status).to be_success, stderr
    stdout
  end

  def seed_sql
    <<~SQL
      PRAGMA foreign_keys = ON;
      INSERT INTO registries (
        id, name, display_name, url, created_at, updated_at
      ) VALUES
        (1, 'rubygems', 'RubyGems.org', 'https://rubygems.org', '2026-08-01', '2026-08-01'),
        (2, 'pypi', 'PyPI', 'https://pypi.org', '2026-08-01', '2026-08-01');
      INSERT INTO adoption_snapshots (
        id, registry_id, taken_on, tracked_packages, provenant_packages,
        tracked_versions, provenant_versions, created_at
      ) VALUES
        (1, 1, '2026-08-09', 1000, 95, 10000, 665, '2026-08-09 01:00:00'),
        (2, 1, '2026-08-15', 1000, 96, 10000, 666, '2026-08-15 01:00:00'),
        (3, 1, '2026-08-17', 1000, 97, 10000, 667, '2026-08-17 01:00:00'),
        (4, 1, '2026-08-21', 1000, 98, 10000, 668, '2026-08-21 01:00:00'),
        (5, 2, '2026-08-21', 100, 12, 1000, 50, '2026-08-21 01:00:00');
    SQL
  end

  def result_query
    <<~SQL
      SELECT r.name AS registry, s.taken_on, s.provenant_packages, s.provenant_versions
      FROM adoption_snapshots s
      INNER JOIN registries r ON r.id = s.registry_id
      ORDER BY r.id, s.taken_on;
    SQL
  end
end
