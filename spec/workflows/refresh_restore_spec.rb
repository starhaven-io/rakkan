# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require "yaml"

RSpec.describe "Refresh Data history restore" do
  let(:steps) do
    YAML.safe_load_file(Hanami.app.root.join(".github", "workflows", "refresh-data.yml"))
        .fetch("jobs").fetch("refresh").fetch("steps")
  end
  let(:step) { steps.find { |candidate| candidate["name"] == "Restore production history" } }

  it "checks the restored data against every remote table count before ingestion" do
    expect(steps.index(step)).to be < steps.index { |candidate| candidate["name"] == "Ingest registry changes" }
    production = steps.find { |candidate| candidate["name"] == "Export current production data" }
    expect(step.fetch("env").fetch("D1_RECOVERY_MANIFEST")).to eq(production.fetch("env").fetch("D1_RECOVERY_MANIFEST"))

    Dir.mktmpdir("rakkan-restore") do |dir|
      Dir.mkdir(File.join(dir, "db"))
      tables = %w[registries packages package_versions adoption_snapshots]
      file = File.join(dir, "data.sql")
      manifest = File.join(dir, "manifest.json")
      File.write(file, tables.map { |table| "CREATE TABLE #{table}(id); INSERT INTO #{table} VALUES (1);" }.join("\n"))
      counts = tables.to_h { |table| [table, 1] }
      restore = lambda do |expected|
        File.write(manifest, JSON.generate(counts: expected))
        Open3.capture2e({ "D1_DATA_SQL" => file, "D1_RECOVERY_MANIFEST" => manifest },
                        "bash", "-euo", "pipefail", "-c", step.fetch("run"), chdir: dir)
      end

      tables.each do |table|
        [0, 2].each do |expected|
          output, status = restore.call(counts.merge(table => expected))
          expect(status).not_to be_success
          expect(output).to include("row count for #{table} differs (restored 1, production #{expected})")
          File.unlink(File.join(dir, "db", "rakkan.sqlite"))
        end
      end

      output, status = restore.call(counts)
      expect(status).to be_success, output
    end
  end
end
