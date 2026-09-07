# frozen_string_literal: true

require "open3"
require "rbconfig"

RSpec.describe "spec database environment" do
  it "rejects non-test environments before loading the application" do
    _stdout, stderr, status = Open3.capture3(
      { "HANAMI_ENV" => "production", "COVERAGE" => nil },
      RbConfig.ruby, "-r./spec/spec_helper", "-e", "abort 'application boot was reached'",
      chdir: Hanami.app.root.to_s
    )

    expect(status.success?).to be(false)
    expect(stderr).to include("The spec suite requires HANAMI_ENV=test")
    expect(stderr).not_to include("application boot was reached")
  end

  it "rejects inherited database paths using connection metadata without opening a database" do
    script = <<~RUBY
      require_relative "spec/support/db/safety"
      db = Struct.new(:opts, :database_type).new({database: ARGV.fetch(0)}, :sqlite)
      SpecDatabaseSafety.validate!(db, root: Dir.pwd)
    RUBY

    ["db/rakkan.sqlite", "/other-checkout/rakkan_test.sqlite"].each do |path|
      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, "-e", script, path, chdir: Hanami.app.root.to_s
      )
      expect(status.success?).to be(false)
      expect(stderr).to include("Refusing test cleanup outside this checkout's db/rakkan_test.sqlite")
    end

    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-e", script, "db/rakkan_test.sqlite", chdir: Hanami.app.root.to_s
    )
    expect(status.success?).to be(true), stderr
  end
end
