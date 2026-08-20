# frozen_string_literal: true

require "json"

# Recorded registry fixtures (see research/ and
# DATA_SOURCES.md). The suite never makes live network calls.
module FixtureHelpers
  FIXTURES_DIR = SPEC_ROOT.join("fixtures")

  def fixture_path(*segments)
    FIXTURES_DIR.join(*segments).to_s
  end

  def json_fixture(name)
    JSON.parse(File.read(fixture_path("api", name)))
  end

  # A stand-in for Ingestion::HTTPClient backed by canned responses.
  # Records every requested URL for assertions.
  class FakeHTTPClient
    attr_reader :accepts, :requests, :ttls

    def initialize(responses = {})
      @responses = responses
      @accepts = []
      @requests = []
      @ttls = []
    end

    def get_json(url, ttl: nil, accept: "application/json")
      @accepts << accept
      @requests << url
      @ttls << ttl
      @responses.fetch(url) { raise "unexpected request in specs: #{url}" }
    end
  end
end

RSpec.configure do |config|
  config.include FixtureHelpers
end
