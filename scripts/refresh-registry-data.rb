#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"

module RegistryRefresh
  ATTEMPTS = 3

  def self.run!(*command)
    return if system(*command)

    raise "#{command.join(" ")} failed"
  end

  def self.count(payload, key, label)
    value = payload[key] if payload.is_a?(Hash)
    return value.to_i if value.is_a?(Numeric) && value >= 0 && value.to_i == value

    raise "ingest:refresh did not report a valid #{label} count"
  end

  def self.summary(message)
    path = ENV.fetch("GITHUB_STEP_SUMMARY", "")
    File.open(path, "a") { |file| file.puts(message) } unless path.empty?
  end

  def self.refresh(registry, refresh_limit, pipeline_date)
    run!("bundle", "exec", "ruby", "research/check_#{registry}_seed_update.rb", "--current", "seed/#{registry}")
    run!("bundle", "exec", "rake", "ingest:seed[#{registry}]")

    if registry == "rubygems"
      1.upto(ATTEMPTS) do |attempt|
        break if system("bundle", "exec", "rake", "ingest:discover[#{registry}]")
        raise "ingest:discover did not drain after #{attempt} attempts" if attempt == ATTEMPTS

        warn "ingest:discover reached its page budget; retrying from its cursor"
      end
    end

    remaining = errors = waived = nil
    1.upto(ATTEMPTS) do |attempt|
      output, status = Open3.capture2("bundle", "exec", "rake",
                                      "ingest:refresh[#{refresh_limit},#{registry},#{pipeline_date}]", binmode: true)
      unless status.success?
        raise "ingest:refresh did not complete within its retry budget" if attempt == ATTEMPTS

        warn "ingest:refresh failed; retrying from its persisted checks"
        next
      end

      puts output
      begin
        payload = JSON.parse(output.sub(/\n+\z/, "").rpartition("\n").last)
      rescue JSON::ParserError
        raise "ingest:refresh did not report a valid remaining count"
      end
      remaining = count(payload, "remaining", "remaining")
      errors = count(payload, "errors", "error")
      waived = count(payload, "waived", "waived")
      break if remaining.zero? && errors.zero?

      if attempt < ATTEMPTS
        warn "#{registry}: #{remaining} tracked versions remain unchecked (#{errors} errors); continuing"
      end
    end

    summary("#{registry}: #{remaining} tracked versions remain unchecked")
    summary("#{registry}: #{errors} provenance errors in the final attempt")
    summary("#{registry}: #{waived} exact provenance 404 waivers in the final attempt")
    raise "#{registry}: provenance errors remain; refusing to publish a snapshot" if errors.positive?

    if remaining.positive?
      summary("#{registry} refresh remains in progress; publishing durable progress without a snapshot")
    else
      run!("bundle", "exec", "rake", "snapshot:take[#{registry},#{pipeline_date}]")
    end
  end

  def self.call(env = ENV)
    registry = env.fetch("REGISTRY", "")
    registry = "rubygems" if registry.empty?
    refresh_limit = env.fetch("REFRESH_LIMIT", "")
    refresh_limit = "250" if refresh_limit.empty?
    pipeline_date = env.fetch("PIPELINE_DATE", "")
    pipeline_date = Time.now.utc.strftime("%F") if pipeline_date.empty?

    raise "registry must be rubygems, cratesio, or all" unless %w[rubygems cratesio all].include?(registry)
    unless refresh_limit.match?(/\A[1-9][0-9]{0,3}\z/) && refresh_limit.to_i <= 1000
      raise "refresh_limit must be an integer from 1 to 1000"
    end
    raise "pipeline date must use YYYY-MM-DD" unless pipeline_date.match?(/\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/)

    registries = registry == "all" ? %w[rubygems cratesio] : [registry]
    registries.each { |name| refresh(name, refresh_limit, pipeline_date) }
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    RegistryRefresh.call
  rescue StandardError => e
    warn e.message
    exit 1
  end
end
