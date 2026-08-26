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
  let(:transport) { ->(_uri, _headers) { raise "transport should not be reached" } }

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
      transport = ->(_uri, _headers) { response(200, body: '[{"ok":true}]') }
      client = described_class.new(cache_dir:, transport:, sleeper: sleeps.method(:push), clock:)

      client.get_json(url)

      cached = described_class.new(cache_dir:)
      expect(cached.get_json(url)).to eq([{ "ok" => true }])
    end

    it "keeps representations with different media types separate" do
      transport = lambda do |_uri, headers|
        response(200, body: JSON.generate({ "accept" => headers.fetch("Accept") }))
      end
      client = described_class.new(cache_dir:, transport:, sleeper: sleeps.method(:push), clock:)

      json = client.get_json(url, accept: "application/json")
      integrity = client.get_json(url, accept: "application/vnd.pypi.integrity.v1+json")

      expect(json).to eq("accept" => "application/json")
      expect(integrity).to eq("accept" => "application/vnd.pypi.integrity.v1+json")
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
      transport = ->(_uri, _headers) { responses.shift }
      client = described_class.new(cache_dir:, transport:, sleeper: sleeps.method(:push), clock:)

      expect(client.get_json(url, ttl: 0)).to eq([])
      expect(sleeps).to eq([7])
    end

    it "honors HTTP-date Retry-After values" do
      retry_at = (Time.now + 30).httpdate
      responses = [response(429, headers: { "Retry-After" => retry_at }), response(200)]
      transport = ->(_uri, _headers) { responses.shift }
      client = described_class.new(cache_dir:, transport:, sleeper: sleeps.method(:push), clock:)

      expect(client.get_json(url, ttl: 0)).to eq([])
      expect(sleeps.size).to eq(1)
      expect(sleeps.first).to be_within(2).of(30)
    end

    it "falls back to exponential backoff on malformed Retry-After" do
      responses = [response(429, headers: { "Retry-After" => "soonish" }), response(200)]
      transport = ->(_uri, _headers) { responses.shift }
      client = described_class.new(cache_dir:, transport:, sleeper: sleeps.method(:push), clock:)

      expect(client.get_json(url, ttl: 0)).to eq([])
      expect(sleeps).to eq([2])
    end

    it "backs off exponentially and gives up after MAX_ATTEMPTS" do
      calls = 0
      transport = lambda { |_uri, _headers|
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
      transport = ->(_uri, _headers) { response(404) }
      client = described_class.new(cache_dir:, transport:, sleeper: sleeps.method(:push), clock:)

      expect(client.get_json(url, ttl: 0)).to be_nil
      expect(sleeps).to be_empty
    end

    it "fails closed on non-retryable errors" do
      transport = ->(_uri, _headers) { response(403) }
      client = described_class.new(cache_dir:, transport:, sleeper: sleeps.method(:push), clock:)

      expect { client.get_json(url, ttl: 0) }
        .to raise_error(described_class::Error, /returned 403/)
      expect(sleeps).to be_empty
    end

    it "reports bounded registry diagnostics for non-retryable errors" do
      detail = "Blocked by crawler policy.\nProvide request id abc123."
      transport = lambda do |_uri, _headers|
        response(403, body: JSON.generate({ "errors" => [nil, { "detail" => detail }] }),
                      headers: { "X-Request-Id" => "abc123" })
      end
      client = described_class.new(cache_dir:, transport:, sleeper: sleeps.method(:push), clock:)

      expect { client.get_json(url, ttl: 0) }
        .to raise_error(
          described_class::Error,
          /returned 403 \(request_id=abc123; Blocked by crawler policy\. Provide request id abc123\.\)/
        )
      expect(sleeps).to be_empty
    end

    it "bounds long registry error details" do
      detail = "x" * (described_class::ERROR_DETAIL_LIMIT + 1)
      transport = lambda do |_uri, _headers|
        response(403, body: JSON.generate({ "errors" => [{ "detail" => detail }] }))
      end
      client = described_class.new(cache_dir:, transport:, sleeper: sleeps.method(:push), clock:)

      expect { client.get_json(url, ttl: 0) }
        .to raise_error(described_class::Error) do |error|
          expect(error.message).to end_with("#{"x" * described_class::ERROR_DETAIL_LIMIT}...)")
          expect(error.message).not_to include("x" * (described_class::ERROR_DETAIL_LIMIT + 1))
        end
    end

    it "bounds request IDs and strips diagnostic control characters" do
      request_id = "#{"r" * 50}\e[2J#{"r" * 60}"
      detail = "blocked \e[32mALL CLEAR\e[0m\u0000"
      transport = lambda do |_uri, _headers|
        response(403, body: JSON.generate({ "errors" => [{ "detail" => detail }] }),
                      headers: { "X-Request-Id" => request_id })
      end
      client = described_class.new(cache_dir:, transport:, sleeper: sleeps.method(:push), clock:)

      expect { client.get_json(url, ttl: 0) }
        .to raise_error(described_class::Error) do |error|
          sanitized_id = error.message[/request_id=([^;]+)/, 1]
          expect(sanitized_id).to end_with("...")
          expect(sanitized_id.length).to eq(described_class::REQUEST_ID_LIMIT + 3)
          expect(error.message).not_to match(/[[:cntrl:]]/)
        end
    end

    it "ignores malformed or empty registry error details" do
      bodies = ["not JSON", '{"errors":[{"detail":123}]}', '{"errors":[{"detail":"  "}]}']

      bodies.each do |body|
        transport = ->(_uri, _headers) { response(403, body:) }
        client = described_class.new(cache_dir:, transport:, sleeper: sleeps.method(:push), clock:)

        expect { client.get_json(url, ttl: 0) }
          .to raise_error(described_class::Error, "GET #{url} returned 403")
      end
    end
  end

  describe "throttling" do
    it "spaces consecutive requests to the minimum interval" do
      times = [0.0, 0.0, 0.1, 0.25]
      clock = -> { times.shift }
      transport = ->(_uri, _headers) { response(200) }
      client = described_class.new(cache_dir:, transport:, sleeper: sleeps.method(:push), clock:)

      client.get_json(url, ttl: 0)
      client.get_json(url, ttl: 0)

      expect(sleeps.size).to eq(1)
      expect(sleeps.first).to be_within(0.001).of(0.15)
    end

    it "paces crates.io at its one-request-per-second policy" do
      times = [0.0, 0.0, 0.25, 1.0]
      clock = -> { times.shift }
      transport = ->(_uri, _headers) { response(200) }
      client = described_class.new(cache_dir:, transport:, sleeper: sleeps.method(:push), clock:)
      crates_url = "https://crates.io/api/v1/crates/serde/1.0.228"

      client.get_json(crates_url, ttl: 0)
      client.get_json(crates_url, ttl: 0)

      expect(sleeps.size).to eq(1)
      expect(sleeps.first).to be_within(0.001).of(0.75)
    end

    it "tracks pacing independently per host" do
      times = [0.0, 0.0, 0.1, 0.1]
      clock = -> { times.shift }
      transport = ->(_uri, _headers) { response(200) }
      client = described_class.new(cache_dir:, transport:, sleeper: sleeps.method(:push), clock:)

      client.get_json("https://crates.io/api/v1/crates/serde/1.0.228", ttl: 0)
      client.get_json(url, ttl: 0)

      expect(sleeps).to be_empty
    end
  end

  describe "streaming downloads" do
    let(:dump_url) { "https://static.crates.io/db-dump.tar.gz" }
    let(:destination) { File.join(cache_dir, "db-dump.tar.gz") }

    it "writes through an atomic partial file with identifying headers" do
      download_transport = lambda do |uri, headers, partial|
        expect(uri.to_s).to eq(dump_url)
        expect(headers).to include(
          "User-Agent" => described_class::USER_AGENT,
          "Accept" => described_class::DOWNLOAD_ACCEPT,
          "Accept-Encoding" => "identity"
        )
        expect(partial).to eq("#{destination}.part")
        File.binwrite(partial, "archive")
        response(200, headers: { "Content-Length" => "7" })
      end
      client = described_class.new(cache_dir:, download_transport:, sleeper: sleeps.method(:push), clock:)

      expect(client.download(dump_url, destination:)).to eq(bytes: 7)
      expect(File.binread(destination)).to eq("archive")
      expect(File).not_to exist("#{destination}.part")
    end

    it "preserves an existing destination when a download fails" do
      File.binwrite(destination, "existing")
      download_transport = ->(_uri, _headers, _partial) { response(403) }
      client = described_class.new(cache_dir:, download_transport:, sleeper: sleeps.method(:push), clock:)

      expect { client.download(dump_url, destination:) }
        .to raise_error(described_class::Error, /returned 403/)
      expect(File.binread(destination)).to eq("existing")
      expect(File).not_to exist("#{destination}.part")
    end

    it "rejects a truncated response without replacing the destination" do
      File.binwrite(destination, "existing")
      download_transport = lambda do |_uri, _headers, partial|
        File.binwrite(partial, "short")
        response(200, headers: { "Content-Length" => "10" })
      end
      client = described_class.new(cache_dir:, download_transport:, sleeper: sleeps.method(:push), clock:)

      expect { client.download(dump_url, destination:) }
        .to raise_error(described_class::Error, /received 5 bytes; expected 10/)
      expect(File.binread(destination)).to eq("existing")
      expect(File).not_to exist("#{destination}.part")
    end

    it "streams the default Net::HTTP response body without buffering it" do
      streamed = response(200)
      streamed.define_singleton_method(:read_body) do |&block|
        %w[arch ive].each(&block)
      end
      http = instance_double(Net::HTTP)
      allow(http).to receive(:request) do |request, &block|
        expect(request["User-Agent"]).to eq(described_class::USER_AGENT)
        expect(request["Accept-Encoding"]).to eq("identity")
        block.call(streamed)
      end
      allow(Net::HTTP).to receive(:start).and_yield(http)
      client = described_class.new(cache_dir:, sleeper: sleeps.method(:push), clock:)

      expect(client.download(dump_url, destination:)).to eq(bytes: 7)
      expect(File.binread(destination)).to eq("archive")
    end

    it "follows the official HTTPS CDN redirect" do
      redirected = response(
        307,
        headers: { "Location" => "https://cloudfront-static.crates.io/db-dump.tar.gz" }
      )
      streamed = response(200, headers: { "Content-Length" => "7" })
      streamed.define_singleton_method(:read_body) { |&block| block.call("archive") }
      responses = [redirected, streamed]
      hosts = []
      http = instance_double(Net::HTTP)
      allow(http).to receive(:request) { |_request, &block| block.call(responses.shift) }
      allow(Net::HTTP).to receive(:start) do |host, _port, **_options, &block|
        hosts << host
        block.call(http)
      end
      time = 0.0
      client = described_class.new(cache_dir:, sleeper: sleeps.method(:push), clock: -> { time += 1.0 })

      expect(client.download(dump_url, destination:)).to eq(bytes: 7)
      expect(hosts).to eq(%w[static.crates.io cloudfront-static.crates.io])
      expect(File.binread(destination)).to eq("archive")
      expect(sleeps).to be_empty
    end

    it "rejects redirects away from the approved CDN" do
      redirected = response(302, headers: { "Location" => "https://example.com/db-dump.tar.gz" })
      http = instance_double(Net::HTTP)
      allow(http).to receive(:request) { |_request, &block| block.call(redirected) }
      allow(Net::HTTP).to receive(:start).and_yield(http)
      client = described_class.new(cache_dir:, sleeper: sleeps.method(:push), clock:)

      expect { client.download(dump_url, destination:) }
        .to raise_error(described_class::Error, /redirected to an unapproved location/)
      expect(File).not_to exist(destination)
    end

    it "retries a transient interruption from a clean partial file" do
      interrupted = response(200)
      interrupted.define_singleton_method(:read_body) do |&block|
        block.call("stale")
        raise Net::ReadTimeout, "stream"
      end
      streamed = response(200, headers: { "Content-Length" => "7" })
      streamed.define_singleton_method(:read_body) { |&block| block.call("archive") }
      responses = [interrupted, streamed]
      http = instance_double(Net::HTTP)
      allow(http).to receive(:request) { |_request, &block| block.call(responses.shift) }
      allow(Net::HTTP).to receive(:start).and_yield(http)
      time = 0.0
      client = described_class.new(cache_dir:, sleeper: sleeps.method(:push), clock: -> { time += 1.0 })

      expect(client.download(dump_url, destination:)).to eq(bytes: 7)
      expect(File.binread(destination)).to eq("archive")
      expect(sleeps).to eq([2])
      expect(File).not_to exist("#{destination}.part")
    end

    it "bounds repeated transport failures" do
      allow(Net::HTTP).to receive(:start).and_raise(Net::ReadTimeout, "stream")
      time = 0.0
      client = described_class.new(cache_dir:, sleeper: sleeps.method(:push), clock: -> { time += 1.0 })

      expect { client.download(dump_url, destination:) }
        .to raise_error(described_class::Error, /failed after 4 attempts \(Net::ReadTimeout\)/)
      expect(sleeps).to eq([2, 4, 8])
      expect(File).not_to exist(destination)
      expect(File).not_to exist("#{destination}.part")
    end

    it "reads a failed default response so registry diagnostics remain available" do
      blocked = response(
        403,
        body: JSON.generate({ "errors" => [{ "detail" => "crawler blocked" }] })
      )
      http = instance_double(Net::HTTP)
      allow(http).to receive(:request) { |_request, &block| block.call(blocked) }
      allow(Net::HTTP).to receive(:start).and_yield(http)
      client = described_class.new(cache_dir:, sleeper: sleeps.method(:push), clock:)

      expect { client.download(dump_url, destination:) }
        .to raise_error(described_class::Error, /returned 403 \(crawler blocked\)/)
    end
  end
end
