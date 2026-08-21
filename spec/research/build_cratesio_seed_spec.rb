# frozen_string_literal: true

require "tmpdir"
require_relative "../../research/build_cratesio_seed"

RSpec.describe CratesioSeedBuilder do
  it "builds a ranked, deterministic version seed without claiming provenance" do
    Dir.mktmpdir("rakkan-cratesio-dump") do |dump_dir|
      data_dir = File.join(dump_dir, "data")
      FileUtils.mkdir_p(data_dir)
      write_dump_fixture(dump_dir, data_dir)

      first_seed = File.join(dump_dir, "seed-one")
      second_seed = File.join(dump_dir, "seed-two")
      first = described_class.build(dump_dir:, seed_dir: first_seed, limit: 2)
      second = described_class.build(dump_dir:, seed_dir: second_seed, limit: 2)

      expect(first).to eq(packages: 2, versions: 3)
      expect(second).to eq(first)
      # The guarantee that travels is the decompressed content: gzip records a
      # platform code and the compressor is not pinned, so identical container
      # bytes hold only within one toolchain. Assert both, so a same-toolchain
      # regression is still caught without claiming portable byte-identity.
      expect(gzip_lines(File.join(first_seed, "tracked_versions.tsv.gz")))
        .to eq(gzip_lines(File.join(second_seed, "tracked_versions.tsv.gz")))
      expect(File.binread(File.join(first_seed, "tracked_versions.tsv.gz")))
        .to eq(File.binread(File.join(second_seed, "tracked_versions.tsv.gz")))
      expect(File.readlines(File.join(first_seed, "top_1000.tsv"), chomp: true)).to eq(
        %W[rank\tcrate_id\tname\tdownloads 1\t2\tbeta\t100 2\t3\tzeta\t100]
      )

      manifest = JSON.parse(File.read(File.join(first_seed, "manifest.json")))
      expect(manifest).to include(
        "dump_taken_at" => "2026-08-20T02:00:21.810126238Z",
        "source_commit" => "42df592c355587e792e7424563b336c7f01344d0",
        "provenance" => "not present in the database dump; seeded versions remain unchecked"
      )

      rows = gzip_lines(File.join(first_seed, "tracked_versions.tsv.gz"))
      expect(rows).to eq(
        [
          "id\tnumber\tcrate_id\tcreated_at\tprerelease\tlatest\tyanked",
          "20\t2.0.0-alpha.1\t2\t2026-08-18 01:00:00\ttrue\tfalse\tfalse",
          "21\t2.0.0\t2\t2026-08-19 01:00:00\tfalse\ttrue\tfalse",
          "30\t3.0.0\t3\t2026-08-20 01:00:00\tfalse\ttrue\ttrue"
        ]
      )
    end
  end

  def write_dump_fixture(dump_dir, data_dir)
    File.write(
      File.join(dump_dir, "metadata.json"),
      JSON.generate(
        timestamp: "2026-08-20T02:00:21.810126238Z",
        crates_io_commit: "42df592c355587e792e7424563b336c7f01344d0"
      )
    )
    File.write(File.join(data_dir, "crate_downloads.csv"), <<~CSV)
      crate_id,downloads
      1,20
      2,100
      3,100
    CSV
    File.write(File.join(data_dir, "crates.csv"), <<~CSV)
      id,name
      1,alpha
      2,beta
      3,zeta
    CSV
    File.write(File.join(data_dir, "default_versions.csv"), <<~CSV)
      crate_id,version_id
      1,10
      2,21
      3,30
    CSV
    File.write(File.join(data_dir, "versions.csv"), <<~CSV)
      id,crate_id,num,created_at,yanked
      10,1,1.0.0,2026-08-17 01:00:00,f
      20,2,2.0.0-alpha.1,2026-08-18 01:00:00,f
      21,2,2.0.0,2026-08-19 01:00:00,f
      30,3,3.0.0,2026-08-20 01:00:00,t
    CSV
  end

  def gzip_lines(path)
    Zlib::GzipReader.open(path) { |gzip| gzip.each_line.map(&:chomp) }
  end
end
