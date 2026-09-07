# frozen_string_literal: true

require "open3"

RSpec.describe "research/probe.rb" do
  it "starts standalone and reports usage without booting Hanami" do
    script = Hanami.app.root.join("research", "probe.rb").to_s

    _stdout, stderr, status = Open3.capture3("bundle", "exec", "ruby", script)

    expect(status).not_to be_success
    expect(stderr).to include("usage: ruby research/probe.rb")
    expect(stderr).not_to include("uninitialized constant Ingestion::HTTPClient::Hanami")
  end
end
