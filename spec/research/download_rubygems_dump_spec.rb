# frozen_string_literal: true

require "digest"
require "tmpdir"
require_relative "../../research/download_rubygems_dump"

RSpec.describe RubygemsDumpDownload do
  it "parses standard current archives and ignores restored Glacier objects" do
    entries = described_class.parse_listing(
      File.read(fixture_path("..", "..", "research", "samples", "rubygems", "dumps_bucket_listing_aug.xml"))
    )

    expect(entries.map { |entry| entry.fetch(:key) }).to contain_exactly(
      "production/public_postgresql/2026.08.03.21.21.43/public_postgresql.tar",
      "production/public_postgresql/2026.08.10.21.21.01/public_postgresql.tar"
    )
    expect(entries.map { |entry| entry.fetch(:size) }).to all(be_positive)
  end

  it "queries only the current and previous month" do
    urls = described_class.listing_urls(Time.utc(2026, 9, 1))

    expect(urls.length).to eq(2)
    expect(urls.join("\n")).to include("2026.08", "2026.09")
  end

  it "bounds listings and the archive to its authoritative listed size" do
    Dir.mktmpdir("rakkan-rubygems-download") do |directory|
      destination = File.join(directory, "public_postgresql.tar")
      key = "production/public_postgresql/2026.08.31.21.21.01/public_postgresql.tar"
      listing = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <IsTruncated>false</IsTruncated>
          <Contents><Key>#{key}</Key><Size>7</Size><StorageClass>STANDARD</StorageClass></Contents>
        </ListBucketResult>
      XML
      client = instance_double(Ingestion::HTTPClient)
      allow(client).to receive(:download) do |url, destination:, **options|
        if url.include?("?list-type=2")
          expect(options).to eq(accept: "application/xml", max_bytes: described_class::MAX_LISTING_BYTES)
          File.write(destination, listing)
        else
          expect(url).to eq("#{RubygemsSeedBuilder::SOURCE_BASE}/#{key}")
          expect(options).to eq(max_bytes: 7)
          File.binwrite(destination, "archive")
        end
        { bytes: File.size(destination) }
      end

      expect(described_class.download(destination:, client:, now: Time.utc(2026, 9, 1))).to eq(
        source_url: "#{RubygemsSeedBuilder::SOURCE_BASE}/#{key}",
        dump_key: key,
        bytes: 7,
        archive_sha256: Digest::SHA256.hexdigest("archive")
      )
    end
  end

  it "rejects a truncated listing rather than guessing at the newest archive" do
    xml = <<~XML
      <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        <IsTruncated>true</IsTruncated>
      </ListBucketResult>
    XML

    expect { described_class.parse_listing(xml) }
      .to raise_error(ArgumentError, /listing was incomplete/)
  end
end
