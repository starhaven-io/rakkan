#!/usr/bin/env ruby
# frozen_string_literal: true

module CheckTools
  PACKAGES = { "zizmor" => "zizmor", "pinprick" => "pinprick", "typos" => "typos-cli" }.freeze

  def self.available?(tool)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
      path = File.join(directory, tool)
      File.file?(path) && File.executable?(path)
    end
  end

  def self.call
    missing = PACKAGES.reject { |tool, _package| available?(tool) }
    if missing.empty?
      puts "All external tools required by just check are available."
      return true
    end

    warn "Missing tools required by just check:"
    missing.each { |tool, package| warn "  - #{tool} (Homebrew package: #{package})" }
    false
  end
end

exit(CheckTools.call ? 0 : 1) if $PROGRAM_NAME == __FILE__
