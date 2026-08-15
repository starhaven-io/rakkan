# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "net/http"
require "time"
require "uri"

module Ingestion
  # Polite HTTP JSON client for registry APIs.
  #
  # - Identifying User-Agent on every request.
  # - Self-imposed request spacing well under rubygems.org's documented
  #   10 req/s limit.
  # - On-disk response cache so reruns never re-fetch (ttl: nil caches
  #   forever; seconds allow refresh; 0 bypasses the read cache).
  # - Exponential backoff on 429/5xx, honoring Retry-After when present.
  #
  # transport/sleeper/clock are injectable so the backoff and throttling
  # behavior is fully testable offline.
  class HTTPClient
    USER_AGENT = "rakkan/0.1 (trusted publishing adoption tracker; +https://rakkan.dev)"
    MIN_INTERVAL = 0.25 # seconds between requests (~4 req/s)
    MAX_ATTEMPTS = 4

    class Error < StandardError
    end

    def initialize(cache_dir: Hanami.app.root.join("var", "cache", "http").to_s,
                   transport: nil,
                   sleeper: Kernel.method(:sleep),
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @cache_dir = cache_dir
      @transport = transport || method(:default_transport)
      @sleeper = sleeper
      @clock = clock
      @last_request_at = nil
    end

    # GET a URL and return parsed JSON (or nil on 404).
    def get_json(url, ttl: nil)
      cached = read_cache(url, ttl:)
      return cached[:json] if cached

      response = fetch_with_backoff(url)
      case response.code.to_i
      when 200
        json = JSON.parse(response.body)
        write_cache(url, response.body)
        json
      when 404
        nil
      else
        raise Error, "GET #{url} returned #{response.code}"
      end
    end

    private

    def fetch_with_backoff(url)
      attempts = 0
      uri = URI(url)
      begin
        attempts += 1
        throttle
        response = @transport.call(uri)
        raise RetryableError, response if retryable?(response)

        response
      rescue RetryableError => e
        raise Error, "GET #{url} failed after #{attempts} attempts (#{e.response.code})" if attempts >= MAX_ATTEMPTS

        @sleeper.call(retry_delay(e.response, attempts))
        retry
      end
    end

    def default_transport(uri)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
        http.get(uri.request_uri, { "User-Agent" => USER_AGENT, "Accept" => "application/json" })
      end
    end

    class RetryableError < StandardError
      attr_reader :response

      def initialize(response)
        @response = response
        super("HTTP #{response.code}")
      end
    end

    def retryable?(response)
      code = response.code.to_i
      code == 429 || code >= 500
    end

    # Retry-After is either delta-seconds or an HTTP-date (RFC 9110); honor
    # both, clamped to something sane, and fall back to exponential backoff.
    def retry_delay(response, attempts)
      header = response["Retry-After"].to_s.strip
      delay =
        if header.match?(/\A\d+\z/)
          header.to_i
        elsif !header.empty?
          begin
            Time.httpdate(header) - Time.now
          rescue ArgumentError
            0
          end
        else
          0
        end
      delay.positive? ? delay.clamp(1, 300) : 2**attempts
    end

    def throttle
      now = @clock.call
      if @last_request_at && (elapsed = now - @last_request_at) < MIN_INTERVAL
        @sleeper.call(MIN_INTERVAL - elapsed)
      end
      @last_request_at = @clock.call
    end

    def cache_path(url)
      File.join(@cache_dir, "#{Digest::SHA256.hexdigest(url)}.json")
    end

    def read_cache(url, ttl:)
      # ttl: 0 means "observe current state": skip the read cache entirely.
      return nil if ttl&.zero?

      path = cache_path(url)
      return nil unless File.exist?(path)

      envelope = JSON.parse(File.read(path))
      return nil if ttl && (Time.now - Time.parse(envelope["fetched_at"])) > ttl

      { json: JSON.parse(envelope["body"]) }
    rescue JSON::ParserError
      nil
    end

    def write_cache(url, body)
      FileUtils.mkdir_p(@cache_dir)
      # Net::HTTP hands back BINARY-tagged bodies; these are JSON, so UTF-8.
      utf8_body = body.dup.force_encoding(Encoding::UTF_8)
      File.write(cache_path(url),
                 JSON.generate({ "url" => url, "fetched_at" => Time.now.iso8601, "body" => utf8_body }))
    end
  end
end
