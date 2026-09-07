# frozen_string_literal: true

require "json"

# Recorded registry fixtures (see research/ and
# DATA_SOURCES.md). The suite never makes live network calls.
module FixtureHelpers
  FIXTURES_DIR = SPEC_ROOT.join("fixtures")

  def fixture_path(*segments)
    FIXTURES_DIR.join(*segments).to_s
  end

  # Recorded registry responses are UTF-8; reading them under a C or POSIX
  # locale would otherwise fail on the first non-ASCII byte.
  def json_fixture(name)
    JSON.parse(File.read(fixture_path("api", name), encoding: "UTF-8"))
  end

  # A stand-in for Ingestion::HTTPClient backed by canned responses.
  # Records every requested URL for assertions.
  class FakeHTTPClient
    attr_reader :accepts, :allow_not_founds, :requests, :ttls

    def initialize(responses = {})
      @responses = responses
      @accepts = []
      @allow_not_founds = []
      @requests = []
      @ttls = []
    end

    def get_json(url, ttl: nil, accept: "application/json", allow_not_found: false)
      @accepts << accept
      @allow_not_founds << allow_not_found
      @requests << url
      @ttls << ttl
      response = @responses.fetch(url) { raise "unexpected request in specs: #{url}" }
      raise Ingestion::HTTPClient::NotFoundError, "GET #{url} returned 404" if response.nil? && !allow_not_found

      response
    end
  end
end

RSpec.configure do |config|
  config.include FixtureHelpers
end
