# frozen_string_literal: true

require "open3"
require "yaml"

RSpec.describe "CI conclusion" do
  let(:workflow) { YAML.safe_load_file(Hanami.app.root.join(".github/workflows/ci.yml")) }
  let(:conclusion) { workflow.fetch("jobs").fetch("conclusion") }
  let(:script) { conclusion.fetch("steps").find { |step| step.fetch("name") == "Result" }.fetch("run") }
  let(:environment) do
    {
      "GITHUB_EVENT_NAME" => "pull_request",
      "COMMITS_RESULT" => "success",
      "ENGINE_RESULT" => "success",
      "SITE_RESULT" => "success",
      "ZIZMOR_RESULT" => "success",
      "PINPRICK_RESULT" => "success",
      "CODEQL_RESULT" => "success",
      "CODECOV_RESULT" => "success",
      "UPLOAD_ALLOWED" => "true"
    }
  end

  def conclude?(overrides = {})
    Open3.capture3(environment.merge(overrides), "/bin/bash", "-euo", "pipefail", "-c", script).last.success?
  end

  it "reports after every dependency and rejects unsuccessful required results" do
    expect(conclusion.fetch("if")).to eq("always()")
    expect(conclusion.fetch("needs")).to contain_exactly(
      "commits", "engine", "site", "zizmor", "pinprick", "codeql", "codecov"
    )
    expect(conclude?).to be(true)
    environment.keys.grep(/_RESULT$/).each do |name|
      ["skipped", "failure", "cancelled", "timed_out", ""].each do |result|
        expect(conclude?(name => result)).to be(false), "#{name}=#{result} must fail"
      end
    end
  end

  it "allows only the pull request checks to be skipped on a push" do
    push = { "GITHUB_EVENT_NAME" => "push" }
    %w[COMMITS_RESULT ZIZMOR_RESULT PINPRICK_RESULT CODEQL_RESULT].each { |name| push[name] = "skipped" }
    expect(conclude?(push)).to be(true)
    %w[ENGINE_RESULT SITE_RESULT CODECOV_RESULT].each do |name|
      expect(conclude?(push.merge(name => "skipped"))).to be(false), "#{name} remains required on push"
    end
  end

  it "permits the explicit fork upload skip without skipping source checks" do
    fork = { "UPLOAD_ALLOWED" => "false", "CODECOV_RESULT" => "skipped" }
    expect(conclude?(fork)).to be(true)
    %w[ENGINE_RESULT SITE_RESULT COMMITS_RESULT ZIZMOR_RESULT PINPRICK_RESULT CODEQL_RESULT].each do |name|
      expect(conclude?(fork.merge(name => "skipped"))).to be(false), "#{name} remains required for a fork"
    end
    expect(conclude?("UPLOAD_ALLOWED" => "")).to be(false)
    expect(conclude?("GITHUB_EVENT_NAME" => "workflow_dispatch")).to be(false)
  end
end
