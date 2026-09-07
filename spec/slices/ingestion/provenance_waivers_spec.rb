# frozen_string_literal: true

require "tmpdir"

RSpec.describe Ingestion::ProvenanceWaivers do
  def load_document(document, today: Date.new(2026, 9, 7))
    Dir.mktmpdir("rakkan-provenance-waivers") do |directory|
      path = File.join(directory, "waivers.json")
      File.write(path, JSON.generate(document))
      return described_class.load(path:, today:)
    end
  end

  def entry(**overrides)
    {
      "registry" => "cratesio",
      "package" => "serde",
      "number" => "1.0.0",
      "platform" => "",
      "reason" => "The registry permanently omits this historical version",
      "expires_on" => "2026-10-01"
    }.merge(overrides.transform_keys(&:to_s))
  end

  it "loads an exact, unexpired identity" do
    waivers = load_document({ "version" => 1, "waivers" => [entry] })

    expect(waivers.find(registry: "cratesio", package: "serde", number: "1.0.0", platform: ""))
      .to have_attributes(reason: /permanently omits/, expires_on: Date.new(2026, 10, 1))
    expect(waivers.find(registry: "cratesio", package: "serde", number: "1.0.1", platform: "")).to be_nil
  end

  it "warns and treats expired entries as inactive without dropping current entries" do
    waivers = nil
    document = {
      "version" => 1,
      "waivers" => [
        entry(
          registry: "rubygems", package: "psych", number: "5.1.0", platform: "ruby",
          expires_on: "2026-09-06"
        ),
        entry(package: "cargo", number: "1.2.3", expires_on: "2026-09-07")
      ]
    }

    expect { waivers = load_document(document) }
      .to output(/ignoring expired provenance waiver.*expired 2026-09-06/).to_stderr

    expect(waivers.find(registry: "rubygems", package: "psych", number: "5.1.0", platform: "ruby")).to be_nil
    expect(waivers.find(registry: "cratesio", package: "cargo", number: "1.2.3", platform: ""))
      .to have_attributes(expires_on: Date.new(2026, 9, 7))
  end

  it "still rejects malformed or noncanonical expiry dates" do
    expect do
      load_document({ "version" => 1, "waivers" => [entry(expires_on: "2026-9-7")] })
    end.to raise_error(ArgumentError, /invalid expiry|noncanonical expiry/)
  end

  it "rejects wildcard identities" do
    expect do
      load_document({ "version" => 1, "waivers" => [entry(number: "1.*")] })
    end.to raise_error(ArgumentError, /wildcard/)
  end

  it "rejects duplicate identities and unexpected fields" do
    expect do
      load_document({ "version" => 1, "waivers" => [entry, entry(reason: "A second rationale")] })
    end.to raise_error(ArgumentError, /unique/)
    expect do
      load_document({ "version" => 1, "waivers" => [entry.merge("pattern" => "*")] })
    end.to raise_error(ArgumentError, /unexpected fields/)
  end

  it "bounds the separately probed waiver set" do
    entries = 101.times.map { |index| entry(number: index.to_s) }

    expect do
      load_document({ "version" => 1, "waivers" => entries })
    end.to raise_error(ArgumentError, /at most 100 entries/)
  end
end
