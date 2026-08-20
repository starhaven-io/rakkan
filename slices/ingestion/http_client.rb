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
  # - Per-host request spacing, including crates.io's 1 req/s ceiling.
  # - On-disk response cache so reruns never re-fetch (ttl: nil caches
  #   forever; seconds allow refresh; 0 bypasses the read cache).
  # - Exponential backoff on 429/5xx, honoring Retry-After when present.
  #
  # transport/sleeper/clock are injectable so the backoff and throttling
  # behavior is fully testable offline.
  class HTTPClient
    USER_AGENT = "rakkan/0.1 (trusted publishing adoption tracker; +https://rakkan.dev)"
    DEFAULT_ACCEPT = "application/json"
    DEFAULT_MIN_INTERVAL = 0.25
    HOST_MIN_INTERVALS = { "crates.io" => 1.0 }.freeze
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
      @last_request_at = {}
    end

    # GET a URL and return parsed JSON (or nil on 404).
    def get_json(url, ttl: nil, accept: DEFAULT_ACCEPT)
      cached = read_cache(url, ttl:, accept:)
      return cached[:json] if cached

      response = fetch_with_backoff(url, accept:)
      case response.code.to_i
      when 200
        json = JSON.parse(response.body)
        write_cache(url, response.body, accept:)
        json
      when 404
        nil
      else
        raise Error, "GET #{url} returned #{response.code}"
      end
    end

    private

    def fetch_with_backoff(url, accept:)
      attempts = 0
      uri = URI(url)
      headers = { "User-Agent" => USER_AGENT, "Accept" => accept }
      begin
        attempts += 1
        throttle(uri.host)
        response = @transport.call(uri, headers)
        raise RetryableError, response if retryable?(response)

        response
      rescue RetryableError => e
        raise Error, "GET #{url} failed after #{attempts} attempts (#{e.response.code})" if attempts >= MAX_ATTEMPTS

        @sleeper.call(retry_delay(e.response, attempts))
        retry
      end
    end

    def default_transport(uri, headers)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
        http.get(uri.request_uri, headers)
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

    def throttle(host)
      now = @clock.call
      interval = HOST_MIN_INTERVALS.fetch(host, DEFAULT_MIN_INTERVAL)
      if @last_request_at[host] && (elapsed = now - @last_request_at.fetch(host)) < interval
        @sleeper.call(interval - elapsed)
      end
      @last_request_at[host] = @clock.call
    end

    def cache_path(url, accept: DEFAULT_ACCEPT)
      cache_key = accept == DEFAULT_ACCEPT ? url : "#{url}\0accept:#{accept}"
      File.join(@cache_dir, "#{Digest::SHA256.hexdigest(cache_key)}.json")
    end

    def read_cache(url, ttl:, accept: DEFAULT_ACCEPT)
      # ttl: 0 means "observe current state": skip the read cache entirely.
      return nil if ttl&.zero?

      path = cache_path(url, accept:)
      return nil unless File.exist?(path)

      envelope = JSON.parse(File.read(path))
      return nil if ttl && (Time.now - Time.parse(envelope["fetched_at"])) > ttl

      { json: JSON.parse(envelope["body"]) }
    rescue JSON::ParserError
      nil
    end

    def write_cache(url, body, accept: DEFAULT_ACCEPT)
      FileUtils.mkdir_p(@cache_dir)
      # Net::HTTP hands back BINARY-tagged bodies; these are JSON, so UTF-8.
      utf8_body = body.dup.force_encoding(Encoding::UTF_8)
      File.write(cache_path(url, accept:),
                 JSON.generate({ "url" => url, "accept" => accept,
                                 "fetched_at" => Time.now.iso8601, "body" => utf8_body }))
    end
  end
end
