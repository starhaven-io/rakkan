# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe "bin/setup" do
  def run_setup(fail_task: "", existing_env: nil)
    Dir.mktmpdir("rakkan-setup") do |root|
      FileUtils.mkdir_p(["#{root}/bin", "#{root}/site/node_modules/.bin"])
      FileUtils.cp(Hanami.app.root.join("bin/setup"), "#{root}/bin/setup")
      File.write("#{root}/.env.example", "example")
      File.write("#{root}/.env", existing_env) if existing_env
      command = <<~RUBY
        #!#{RbConfig.ruby}
        File.open(ENV.fetch("CALLS"), "a") do |file|
          file.puts([File.basename($PROGRAM_NAME), *ARGV].join(" "))
        end
        exit 1 if ARGV.join(" ") == ENV.fetch("FAIL_TASK")
      RUBY
      %w[bundle node npm].each do |name|
        File.write("#{root}/bin/#{name}", command, perm: 0o755)
      end
      File.write("#{root}/site/node_modules/.bin/wrangler", command, perm: 0o755)
      env = {
        "PATH" => "#{root}/bin:/usr/bin:/bin", "CALLS" => "#{root}/calls", "FAIL_TASK" => fail_task
      }
      _stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "#{root}/bin/setup", unsetenv_others: true)
      yield status:, stderr:, calls: File.readlines("#{root}/calls", chomp: true), env: File.read("#{root}/.env")
    end
  end

  it "sets up offline data and local D1 after checked dependency installation" do
    run_setup(fail_task: "check") do |result|
      expect(result.fetch(:status)).to be_success, result.fetch(:stderr)
      expect(result.fetch(:env)).to eq("example")
      expect(result.fetch(:calls)).to eq(
        [
          "bundle check", "bundle install", "bundle exec hanami db prepare",
          "bundle exec rake ingest:seed", "bundle exec rake ingest:seed[cratesio]", "bundle exec rake snapshot:take",
          "node scripts/check-npm-install-policy.mjs site", "npm ci --strict-allow-scripts",
          "bundle exec rake export:d1",
          "wrangler d1 execute rakkan --local --file=../db/d1_export.sql"
        ]
      )
    end
  end

  it "preserves an existing environment and stops after a failed policy check" do
    run_setup(fail_task: "scripts/check-npm-install-policy.mjs site", existing_env: "custom") do |result|
      expect(result.fetch(:status)).not_to be_success
      expect(result.fetch(:env)).to eq("custom")
      expect(result.fetch(:calls)).not_to include("bundle install", "npm ci --strict-allow-scripts")
      expect(result.fetch(:calls).last).to eq("node scripts/check-npm-install-policy.mjs site")
    end
  end
end
