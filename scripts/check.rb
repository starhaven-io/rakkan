#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "check-tools"

class RepositoryCheck
  def initialize
    @failed = false
    @skipped = []
  end

  def run(name, *command, **)
    puts "--- #{name} ---"
    @failed = true unless system(*command, **)
  end

  def skip(name, tool, package)
    puts "--- #{name} --- skipped (#{tool} not found)"
    @skipped << "#{tool} (brew install #{package})"
  end

  def run_tool(name, tool, package, *command)
    if CheckTools.available?(tool)
      run(name, *command)
    else
      skip(name, tool, package)
    end
  end

  def call
    run("tools", "ruby", "scripts/check-tools.rb")
    run("npm-policy", "node", "scripts/check-npm-install-policy.mjs", "site")
    run("seeds", "just", "check-seeds")
    run("rspec", { "COVERAGE" => "true" }, "bundle", "exec", "rspec")
    run("rubocop", "bundle", "exec", "rubocop", "--cache-root", "var/cache/rubocop")
    run_tool("zizmor", "zizmor", "zizmor", "zizmor", "--strict-collection", "--persona", "auditor",
             ".github/workflows/")
    run_tool("pinprick", "pinprick", "pinprick", "pinprick", "audit", ".")
    if File.directory?("site/node_modules")
      { "site-format" => "format:check", "site-check" => "check", "site-tests" => "test:coverage" }.each do |name, task|
        run(name, "npm", "run", "--silent", task, chdir: "site")
      end
      run("site-build", "./node_modules/.bin/astro", "build", "--silent", chdir: "site", out: File::NULL)
    else
      skip("site-tests", "node_modules", "just install-site")
    end
    run_tool("typos", "typos", "typos-cli", "typos")
    unless @skipped.empty?
      puts "\nChecks skipped due to missing tools:"
      @skipped.each { |tool| puts "  - #{tool}" }
    end
    !@failed && @skipped.empty?
  end
end

exit(RepositoryCheck.new.call ? 0 : 1) if $PROGRAM_NAME == __FILE__
