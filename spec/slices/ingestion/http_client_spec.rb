# frozen_string_literal: true

require "tmpdir"

RSpec.describe Ingestion::HTTPClient do
  subject(:client) do
    described_class.new(cache_dir:, transport:, sleeper: sleeps.method(:push), clock:)
  end

  let(:cache_dir) { Dir.mktmpdir("rakkan-http-cache") }
  let(:url) { "https://rubygems.org/api/v1/attestations/example-1.0.0.json" }
  let(:sleeps) { [] }
  let(:clock) { -> { 1000.0 } }
  let(:transport) { ->(_uri) { raise "transport should not be reached" } }

  after { FileUtils.remove_entry(cache_dir) }

  # Minimal Net::HTTPResponse stand-in: code, body, and header lookup.
  def response(code, body: "[]", headers: {})
    resp = Struct.new(:code, :body, :headers) do
      def [](key) = headers[key]
    end
    resp.new(code.to_s, body, headers)
  end

  describe "caching" do
    it "serves cached responses without touching the transport" do
      client.send(:write_cache, url, JSON.generate([{ "mediaType" => "cached" }]))

      expect(client.get_json(url)).to eq([{ "mediaType" => "cached" }])
    end

    it "treats expired cache entries as misses" do
      client.send(:write_cache, url, "[]")

      expect(client.send(:read_cache, url, ttl: nil)).not_to be_nil
      sleep 0.01
      expect(client.send(:read_cache, url, ttl: 0.001)).to be_nil
    end

    it "treats ttl 0 as a full cache bypass" do
      client.send(:write_cache, url, "[]")

      expect(client.send(:read_cache, url, ttl: 0)).to be_nil
    end

    it "ignores corrupt cache files" do
      FileUtils.mkdir_p(cache_dir)
      File.write(client.send(:cache_path, url), "not json")

      expect(client.send(:read_cache, url, ttl: nil)).to be_nil
    end

    it "writes successful responses to the cache" do
      transport = ->(_uri) { response(200, body: '[{"ok":true}]') }
      client = described_class.new(cache_dir:, transport:, sleeper: sleeps.method(:push), clock:)

      client.get_json(url)

      cached = described_class.new(cache_dir:)
      expect(cached.get_json(url)).to eq([{ "ok" => true }])
    end
  end

  describe "backoff" do
    # A clock that advances past MIN_INTERVAL on every reading keeps the
    # throttle quiet so only backoff sleeps are observed.
    let(:clock) do
      t = 0.0
      -> { t += 1.0 }
    end

    it "honors Retry-After on 429 and then succeeds" do
      responses = [response(429, headers: { "Retry-After" => "7" }), response(200)]
      transport = ->(_uri) { responses.shift }
      client = described_class.new(cache_dir:, transport:, sleeper: sleeps.method(:push), clock:)

      expect(client.get_json(url, ttl: 0)).to eq([])
      expect(sleeps).to eq([7])
    end

    it "honors HTTP-date Retry-After values" do
      retry_at = (Time.now + 30).httpdate
      responses = [response(429, headers: { "Retry-After" => retry_at }), response(200)]
      transport = ->(_uri) { responses.shift }
      client = described_class.new(cache_dir:, transport:, sleeper: sleeps.method(:push), clock:)

      expect(client.get_json(url, ttl: 0)).to eq([])
      expect(sleeps.size).to eq(1)
      expect(sleeps.first).to be_within(2).of(30)
    end

    it "falls back to exponential backoff on malformed Retry-After" do
      responses = [response(429, headers: { "Retry-After" => "soonish" }), response(200)]
      transport = ->(_uri) { responses.shift }
      client = described_class.new(cache_dir:, transport:, sleeper: sleeps.method(:push), clock:)

      expect(client.get_json(url, ttl: 0)).to eq([])
      expect(sleeps).to eq([2])
    end

    it "backs off exponentially and gives up after MAX_ATTEMPTS" do
      calls = 0
      transport = lambda { |_uri|
        calls += 1
        response(500)
      }
      client = described_class.new(cache_dir:, transport:, sleeper: sleeps.method(:push), clock:)

      expect { client.get_json(url, ttl: 0) }
        .to raise_error(described_class::Error, /failed after 4 attempts \(500\)/)
      expect(calls).to eq(4)
      expect(sleeps).to eq([2, 4, 8])
    end

    it "returns nil on 404 without retrying" do
      transport = ->(_uri) { response(404) }
      client = described_class.new(cache_dir:, transport:, sleeper: sleeps.method(:push), clock:)

      expect(client.get_json(url, ttl: 0)).to be_nil
      expect(sleeps).to be_empty
    end
  end

  describe "throttling" do
    it "spaces consecutive requests to the minimum interval" do
      times = [0.0, 0.0, 0.1, 0.25]
      clock = -> { times.shift }
      transport = ->(_uri) { response(200) }
      client = described_class.new(cache_dir:, transport:, sleeper: sleeps.method(:push), clock:)

      client.get_json(url, ttl: 0)
      client.get_json(url, ttl: 0)

      expect(sleeps.size).to eq(1)
      expect(sleeps.first).to be_within(0.001).of(0.15)
    end
  end
end
