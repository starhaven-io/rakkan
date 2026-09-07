# frozen_string_literal: true

require "tmpdir"
require_relative "../../research/build_seed"
require_relative "../../research/check_rubygems_seed_update"
require_relative "../../research/extract_dump"
require_relative "../../research/filter_versions"
require_relative "../../research/top_gems"

RSpec.describe "RubyGems seed pipeline" do
  let(:dump_key) { "production/public_postgresql/2026.08.10.21.21.01/public_postgresql.tar" }
  let(:archive_sha256) { "a" * 64 }

  it "builds and semantically verifies a deterministic seed using COPY column names" do
    Dir.mktmpdir("rakkan-rubygems-pipeline") do |root|
      sql_gz = File.join(root, "PostgreSQL.sql.gz")
      write_dump(sql_gz)
      extracted = File.join(root, "extracted")
      seed_one = File.join(root, "seed-one")
      seed_two = File.join(root, "seed-two")

      counts = RubygemsDumpExtractor.extract(
        sql_gz:, output_dir: extracted, tables: %w[rubygems gem_downloads attestations]
      )
      expect(counts).to include("rubygems" => 1_000, "gem_downloads" => 2_000, "attestations" => 1)
      RubygemsTopPackages.build(
        extracted_dir: extracted, limit: 1_000, output_path: File.join(extracted, "top_1000.tsv")
      )
      RubygemsVersionFilter.filter(
        sql_gz:, tracked_packages_path: File.join(extracted, "top_1000.tsv"),
        output_path: File.join(extracted, "tracked_versions.tsv")
      )

      first = RubygemsSeedBuilder.build(extracted_dir: extracted, seed_dir: seed_one, dump_key:, archive_sha256:)
      second = RubygemsSeedBuilder.build(extracted_dir: extracted, seed_dir: seed_two, dump_key:, archive_sha256:)

      expect(first).to eq(packages: 1_000, versions: 1_000, attestations: 1)
      expect(second).to eq(first)
      RubygemsSeedBuilder.expected_files.each do |name|
        expect(File.binread(File.join(seed_one, name))).to eq(File.binread(File.join(seed_two, name)))
      end
      rows = File.readlines(File.join(seed_one, "top_1000.tsv"), chomp: true)
      expect(rows.first(4).map { |row| row.split("\t")[2] }).to eq(%w[name rack alpha zeta])
      expect(
        RubygemsSeedUpdate.validate_current(seed_dir: seed_one, now: Time.utc(2026, 8, 11))
      ).to eq(dump_taken_at: "2026-08-10T21:21:01Z")
    end
  end

  it "publishes a newer exact-source manifest when decompressed content is unchanged" do
    Dir.mktmpdir("rakkan-rubygems-comparison") do |root|
      sql_gz = File.join(root, "PostgreSQL.sql.gz")
      write_dump(sql_gz)
      extracted = prepare_extract(root, sql_gz)
      current = File.join(root, "current")
      candidate = File.join(root, "candidate")
      RubygemsSeedBuilder.build(extracted_dir: extracted, seed_dir: current, dump_key:, archive_sha256:)
      RubygemsSeedBuilder.build(
        extracted_dir: extracted,
        seed_dir: candidate,
        dump_key: "production/public_postgresql/2026.08.17.21.21.01/public_postgresql.tar",
        archive_sha256: "b" * 64
      )

      result = RubygemsSeedUpdate.check(current_seed: current, candidate_seed: candidate, now: Time.utc(2026, 8, 18))
      expect(result).to include(
        update_required: true, content_changed: false, packages: 1_000, versions: 1_000, attestations: 1
      )
    end
  end

  it "treats the exact current dump as a successful no-op" do
    Dir.mktmpdir("rakkan-rubygems-no-op") do |root|
      sql_gz = File.join(root, "PostgreSQL.sql.gz")
      write_dump(sql_gz)
      extracted = prepare_extract(root, sql_gz)
      current = File.join(root, "current")
      candidate = File.join(root, "candidate")
      RubygemsSeedBuilder.build(extracted_dir: extracted, seed_dir: current, dump_key:, archive_sha256:)
      RubygemsSeedBuilder.build(extracted_dir: extracted, seed_dir: candidate, dump_key:, archive_sha256:)

      expect(
        RubygemsSeedUpdate.check(current_seed: current, candidate_seed: candidate, now: Time.utc(2026, 8, 11))
      ).to include(update_required: false, content_changed: false)
    end
  end

  it "separates structural validation from the protected freshness gate" do
    Dir.mktmpdir("rakkan-rubygems-stale-structural") do |root|
      seed = build_fixture_seed(root)
      stale_now = Time.utc(2026, 8, 20)

      expect(RubygemsSeedUpdate.validate_current(seed_dir: seed, now: stale_now, require_fresh: false))
        .to eq(dump_taken_at: "2026-08-10T21:21:01Z")
      expect { RubygemsSeedUpdate.validate_current(seed_dir: seed, now: stale_now) }
        .to raise_error(ArgumentError, /more than 9 days old/)
    end
  end

  it "requires archive identity in every current manifest" do
    %w[source_url archive_sha256].each do |field|
      Dir.mktmpdir("rakkan-rubygems-manifest-validation") do |root|
        seed = build_fixture_seed(root)
        path = File.join(seed, "manifest.json")
        manifest = JSON.parse(File.read(path, encoding: "UTF-8"))
        manifest.delete(field)
        File.write(path, JSON.pretty_generate(manifest))

        expect { RubygemsSeedUpdate.validate_current(seed_dir: seed, now: Time.utc(2026, 8, 11)) }
          .to raise_error(ArgumentError)
      end
    end
  end

  it "binds the canonical dump timestamp to the immutable dump key" do
    Dir.mktmpdir("rakkan-rubygems-manifest-timestamp") do |root|
      seed = build_fixture_seed(root)
      path = File.join(seed, "manifest.json")
      manifest = JSON.parse(File.read(path, encoding: "UTF-8"))
      manifest["dump_taken_at"] = "2026-08-11T21:21:01Z"
      File.write(path, JSON.pretty_generate(manifest))

      expect { RubygemsSeedUpdate.validate_current(seed_dir: seed, now: Time.utc(2026, 8, 12)) }
        .to raise_error(ArgumentError, /dump_taken_at does not match its dump key/)
    end
  end

  it "rejects impossible dates encoded in a dump key" do
    expect do
      RubygemsSeedBuilder.dump_timestamp(
        "production/public_postgresql/2026.02.31.21.21.01/public_postgresql.tar"
      )
    end.to raise_error(ArgumentError, "invalid RubyGems dump key")
  end

  it "rejects truncated COPY data without publishing partial extracts" do
    Dir.mktmpdir("rakkan-rubygems-truncated") do |root|
      sql_gz = File.join(root, "PostgreSQL.sql.gz")
      Zlib::GzipWriter.open(sql_gz) do |gzip|
        gzip.write("COPY public.rubygems (id, name, indexed) FROM stdin;\n1\track\tt\n")
      end
      output = File.join(root, "output")

      expect { RubygemsDumpExtractor.extract(sql_gz:, output_dir: output, tables: ["rubygems"]) }
        .to raise_error(ArgumentError, /unterminated/)
      expect(Dir.glob(File.join(output, "*"))).to be_empty
    end
  end

  it "rejects version rows whose semantic flags or timestamps are inconsistent" do
    cases = {
      "prerelease flag does not match" => ->(fields) { fields[6] = "t" },
      "tracked packages have no latest version" => ->(fields) { fields[7] = "f" },
      "yanked_at is after the dump" => ->(fields) { fields[8] = "2026-08-12 00:00:00" }
    }

    cases.each do |message, mutation|
      Dir.mktmpdir("rakkan-rubygems-version-validation") do |root|
        seed = build_fixture_seed(root)
        rewrite_first_gzip_row(File.join(seed, "tracked_versions.tsv.gz"), &mutation)

        expect { RubygemsSeedUpdate.validate_current(seed_dir: seed, now: Time.utc(2026, 8, 11)) }
          .to raise_error(ArgumentError, /#{message}/)
      end
    end
  end

  it "rejects malformed or temporally impossible attestation rows" do
    cases = {
      "attestation body must be an object" => ->(fields) { fields[2] = "[]" },
      "attestation media type does not match" => ->(fields) { fields[3] = "application/other" },
      "attestation body is not parseable" => lambda do |fields|
        body = JSON.parse(fields[2])
        body.fetch("verificationMaterial").fetch("certificate")["rawBytes"] = "not-base64"
        fields[2] = JSON.generate(body)
      end,
      "attestation timestamp is after the dump" => ->(fields) { fields[5] = "2026-08-12 00:00:00" }
    }

    cases.each do |message, mutation|
      Dir.mktmpdir("rakkan-rubygems-attestation-validation") do |root|
        seed = build_fixture_seed(root)
        rewrite_first_gzip_row(File.join(seed, "tracked_attestations.tsv.gz"), &mutation)

        expect { RubygemsSeedUpdate.validate_current(seed_dir: seed, now: Time.utc(2026, 8, 11)) }
          .to raise_error(ArgumentError, /#{message}/)
      end
    end
  end

  def prepare_extract(root, sql_gz)
    extracted = File.join(root, "extracted")
    RubygemsDumpExtractor.extract(
      sql_gz:, output_dir: extracted, tables: %w[rubygems gem_downloads attestations]
    )
    RubygemsTopPackages.build(
      extracted_dir: extracted, limit: 1_000, output_path: File.join(extracted, "top_1000.tsv")
    )
    RubygemsVersionFilter.filter(
      sql_gz:, tracked_packages_path: File.join(extracted, "top_1000.tsv"),
      output_path: File.join(extracted, "tracked_versions.tsv")
    )
    extracted
  end

  def build_fixture_seed(root)
    sql_gz = File.join(root, "PostgreSQL.sql.gz")
    write_dump(sql_gz)
    extracted = prepare_extract(root, sql_gz)
    seed = File.join(root, "seed")
    RubygemsSeedBuilder.build(extracted_dir: extracted, seed_dir: seed, dump_key:, archive_sha256:)
    seed
  end

  def rewrite_first_gzip_row(path)
    lines = Zlib::GzipReader.open(path, external_encoding: "UTF-8", &:readlines)
    fields = lines.fetch(1).chomp.split("\t", -1)
    yield fields
    lines[1] = "#{fields.join("\t")}\n"
    Zlib::GzipWriter.open(path, external_encoding: "UTF-8") do |gzip|
      gzip.mtime = 0
      gzip.write(lines.join)
    end
  end

  def write_dump(path)
    Zlib::GzipWriter.open(path) do |gzip|
      gzip.puts "COPY public.rubygems (id, name, created_at, updated_at, indexed, organization_id) FROM stdin;"
      1.upto(1_000) do |id|
        name = case id
               when 1 then "rack"
               when 2 then "zeta"
               when 3 then "alpha"
               else format("gem-%04d", id)
               end
        gzip.puts [id, name, "2020-01-01", "2026-08-10", "t", "\\N"].join("\t")
      end
      gzip.puts "\\."

      gzip.puts "COPY public.gem_downloads (count, version_id, rubygem_id, id) FROM stdin;"
      1.upto(1_000) do |id|
        total = id.between?(2, 3) ? 1_999_998 : 2_000_000 - id
        gzip.puts [total, 0, id, id].join("\t")
        gzip.puts [total - 1, 10_000 + id, id, 10_000 + id].join("\t")
      end
      gzip.puts "\\."

      gzip.puts "COPY public.attestations (body, id, version_id, media_type, created_at, updated_at) FROM stdin;"
      attestation = json_fixture("v1_attestations_sigstore-0.2.3.json").first
      attestation_body = JSON.generate(attestation).gsub("\\") { "\\\\" }
      gzip.puts [attestation_body, 1, 10_001, attestation.fetch("mediaType"), "2026-08-10",
                 "2026-08-10"].join("\t")
      gzip.puts "\\."

      gzip.puts "COPY public.versions " \
                "(number, id, created_at, rubygem_id, platform, indexed, prerelease, latest, " \
                "yanked_at, pusher_id, pusher_api_key_id) FROM stdin;"
      1.upto(1_000) do |id|
        gzip.puts ["1.0.0", 10_000 + id, "2026-08-10 20:00:00", id, "ruby", "t", "f", "t", "\\N", "\\N",
                   "\\N"].join("\t")
      end
      gzip.puts "\\."
    end
  end
end
