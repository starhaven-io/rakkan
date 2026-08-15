# frozen_string_literal: true

require "net/http"

# The suite-wide guarantee behind "no live calls in tests": the only HTTP
# entry point in the app is Net::HTTP.start (via Ingestion::HTTPClient's
# default transport), and it is disabled for every example. Specs exercise
# HTTP behavior through injected fake transports instead.
RSpec.configure do |config|
  config.before do
    allow(Net::HTTP).to receive(:start)
      .and_raise("Outbound network is disabled in the spec suite")
  end
end
