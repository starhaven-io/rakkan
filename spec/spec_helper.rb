# frozen_string_literal: true

if ENV["COVERAGE"] == "true"
  require "simplecov"
  require "simplecov-cobertura"

  SimpleCov.start do
    enable_coverage :branch
    cover "{app,lib,slices}/**/*.rb", "lib/tasks/*.rake"
    formatter SimpleCov::Formatter::CoberturaFormatter
  end
end

SPEC_ROOT = Pathname(__dir__).realpath.freeze

ENV["HANAMI_ENV"] ||= "test"
require "hanami/prepare"

SPEC_ROOT.glob("support/**/*.rb").each { |f| require f }
