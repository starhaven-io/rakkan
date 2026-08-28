# frozen_string_literal: true

require "tmpdir"
require_relative "../../research/check_cratesio_seed_update"

RSpec.describe CratesioSeedUpdate do
  let(:now) { Time.iso8601("2026-08-25T05:00:00Z") }
  let(:source_commit) { "42df592c355587e792e7424563b336c7f01344d0" }

  it "ignores manifest and gzip-container churn when seed content is unchanged" do
    with_seed_pair do |current_seed, candidate_seed|
      write_seed(current_seed, taken_at: "2026-08-18T02:00:00Z")
      write_seed(candidate_seed, taken_at: "2026-08-25T02:00:00Z", source_commit: "a" * 40)
      rewrite_gzip_platform_byte(candidate_seed)

      result = described_class.check(current_seed:, candidate_seed:, now:)

      expect(result).to include(
        update_required: false,
        dump_taken_at: "2026-08-25T02:00:00Z",
        source_commit: "a" * 40,
        packages: 1_000,
        versions: 2
      )
      expect(result.fetch(:packages_sha256)).to match(/\A[0-9a-f]{64}\z/)
      expect(result.fetch(:versions_sha256)).to match(/\A[0-9a-f]{64}\z/)
    end
  end

  it "detects changes in decompressed version content" do
    with_seed_pair do |current_seed, candidate_seed|
      write_seed(current_seed, taken_at: "2026-08-18T02:00:00Z")
      write_seed(
        candidate_seed,
        taken_at: "2026-08-25T02:00:00Z",
        versions: ["1\t1.0.0", "2\t2.0.1"]
      )

      expect(described_class.check(current_seed:, candidate_seed:, now:))
        .to include(update_required: true, versions: 2)
    end
  end

  it "detects changes in tracked package content" do
    with_seed_pair do |current_seed, candidate_seed|
      write_seed(current_seed, taken_at: "2026-08-18T02:00:00Z")
      write_seed(candidate_seed, taken_at: "2026-08-25T02:00:00Z", package_downloads: 2)

      expect(described_class.check(current_seed:, candidate_seed:, now:))
        .to include(update_required: true, packages: 1_000)
    end
  end

  it "rejects a candidate that is not newer than the committed seed" do
    with_seed_pair do |current_seed, candidate_seed|
      write_seed(current_seed, taken_at: "2026-08-25T02:00:00Z")
      write_seed(candidate_seed, taken_at: "2026-08-25T02:00:00Z")

      expect { described_class.check(current_seed:, candidate_seed:, now:) }
        .to raise_error(ArgumentError, /not newer than the committed seed/)
    end
  end

  it "rejects a candidate more than two days old" do
    with_seed_pair do |current_seed, candidate_seed|
      write_seed(current_seed, taken_at: "2026-08-01T02:00:00Z")
      write_seed(candidate_seed, taken_at: "2026-08-22T02:00:00Z")

      expect { described_class.check(current_seed:, candidate_seed:, now:) }
        .to raise_error(ArgumentError, /more than 2 days old/)
    end
  end

  it "rejects a candidate timestamp beyond the clock-skew allowance" do
    with_seed_pair do |current_seed, candidate_seed|
      write_seed(current_seed, taken_at: "2026-08-18T02:00:00Z")
      write_seed(candidate_seed, taken_at: "2026-08-25T05:05:01Z")

      expect { described_class.check(current_seed:, candidate_seed:, now:) }
        .to raise_error(ArgumentError, /timestamp is in the future/)
    end
  end

  it "rejects an incomplete tracked package set" do
    with_seed_pair do |current_seed, candidate_seed|
      write_seed(current_seed, taken_at: "2026-08-18T02:00:00Z")
      write_seed(candidate_seed, taken_at: "2026-08-25T02:00:00Z", packages: 999)

      expect { described_class.check(current_seed:, candidate_seed:, now:) }
        .to raise_error(ArgumentError, /exactly 1000 packages/)
    end
  end

  it "rejects drift in the manifest contract" do
    with_seed_pair do |current_seed, candidate_seed|
      write_seed(current_seed, taken_at: "2026-08-18T02:00:00Z")
      write_seed(candidate_seed, taken_at: "2026-08-25T02:00:00Z", source: "some mirror")

      expect { described_class.check(current_seed:, candidate_seed:, now:) }
        .to raise_error(ArgumentError, /candidate seed has an unexpected source/)
    end
  end

  def with_seed_pair
    Dir.mktmpdir("rakkan-cratesio-seed-update") do |root|
      current_seed = File.join(root, "current")
      candidate_seed = File.join(root, "candidate")
      FileUtils.mkdir_p([current_seed, candidate_seed])
      yield current_seed, candidate_seed
    end
  end

  def write_seed(seed_dir, taken_at:, source_commit: self.source_commit,
                 source: "crates.io daily database dump", packages: 1_000,
                 package_downloads: 1,
                 versions: ["1\t1.0.0", "2\t2.0.0"])
    manifest = {
      source: source,
      source_url: CratesioSeedBuilder::SOURCE_URL,
      dump_taken_at: taken_at,
      source_commit: source_commit,
      built_by: "research/build_cratesio_seed.rb",
      tracked_set: "top 1000 crates by total downloads (crate_downloads.csv)",
      provenance: "not present in the database dump; seeded versions remain unchecked"
    }
    File.write(File.join(seed_dir, "manifest.json"), JSON.generate(manifest))
    package_rows = Array.new(packages) do |index|
      "#{index + 1}\t#{index + 1}\tcrate-#{index + 1}\t#{package_downloads}\n"
    end
    File.write(
      File.join(seed_dir, "top_1000.tsv"),
      [CratesioSeedUpdate::PACKAGE_HEADER, *package_rows].join
    )
    Zlib::GzipWriter.open(File.join(seed_dir, "tracked_versions.tsv.gz")) do |gzip|
      gzip.mtime = 0
      gzip.write(CratesioSeedUpdate::VERSION_HEADER)
      versions.each { |version| gzip.puts("#{version}\t1\t2026-08-20 00:00:00\tfalse\tfalse\tfalse") }
    end
  end

  def rewrite_gzip_platform_byte(seed_dir)
    path = File.join(seed_dir, "tracked_versions.tsv.gz")
    bytes = File.binread(path)
    bytes.setbyte(9, bytes.getbyte(9) == 3 ? 0 : 3)
    File.binwrite(path, bytes)
  end
end
