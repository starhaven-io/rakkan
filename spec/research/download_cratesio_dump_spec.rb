# frozen_string_literal: true

require "tmpdir"
require_relative "../../research/download_cratesio_dump"

RSpec.describe CratesioDumpDownload do
  it "downloads the official archive through the bounded ingestion client" do
    Dir.mktmpdir("rakkan-cratesio-download") do |directory|
      destination = File.join(directory, "dump.tar.gz")
      client = instance_double(Ingestion::HTTPClient)
      File.binwrite(destination, "archive")
      expect(client).to receive(:download)
        .with(
          CratesioSeedBuilder::SOURCE_URL,
          destination:,
          max_bytes: described_class::MAX_ARCHIVE_BYTES
        )
        .and_return(bytes: 123)

      expect(described_class.download(destination:, client:)).to eq(
        source_url: CratesioSeedBuilder::SOURCE_URL,
        archive_sha256: Digest::SHA256.hexdigest("archive"),
        bytes: 123
      )
    end
  end

  it "rejects an empty archive" do
    client = instance_double(Ingestion::HTTPClient, download: { bytes: 0 })

    expect { described_class.download(destination: "/tmp/unused", client:) }
      .to raise_error(Ingestion::HTTPClient::Error, /dump is empty/)
  end
end
