# frozen_string_literal: true

require "date"
require "digest"
require "json"
require "time"

class D1ExportManifest
  KEYS = %w[counts database export_sha256 generated_at schema_version version].freeze
  COUNT_KEYS = %w[adoption_snapshots package_versions packages registries].freeze
  SQLITE_UTC = /\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{6}\z/
  SHA256 = /\A[0-9a-f]{64}\z/

  def self.verify(manifest_path, export_path)
    [manifest_path, export_path].each do |path|
      stat = File.lstat(path)
      next if stat.file? && !stat.symlink?

      raise ArgumentError, "export artifact must be regular and not a symlink: #{path}"
    end
    raise ArgumentError, "export manifest is too large" if File.size(manifest_path) > 65_536

    document = JSON.parse(File.read(manifest_path, encoding: "UTF-8"))
    unless document.is_a?(Hash) && document.keys.sort == KEYS && document["version"] == 1 &&
           document["database"] == "rakkan"
      raise ArgumentError, "export manifest has an unknown shape or version"
    end
    unless document["schema_version"].is_a?(Integer) && document["schema_version"].positive?
      raise ArgumentError, "export manifest has an invalid schema version"
    end
    unless sqlite_utc?(document["generated_at"])
      raise ArgumentError, "export manifest has an invalid generation timestamp"
    end

    counts = document["counts"]
    valid_counts = counts.is_a?(Hash) && counts.keys.sort == COUNT_KEYS &&
                   counts.values.all? { |value| value.is_a?(Integer) && value.positive? }
    raise ArgumentError, "export manifest must contain positive exact table counts" unless valid_counts

    expected_hash = document["export_sha256"]
    unless expected_hash.is_a?(String) && expected_hash.match?(SHA256) &&
           Digest::SHA256.file(export_path).hexdigest == expected_hash
      raise ArgumentError, "D1 export checksum does not match the manifest"
    end

    document
  rescue Errno::ENOENT, JSON::ParserError => e
    raise ArgumentError, "invalid export artifact: #{e.message}"
  end

  def self.sqlite_utc?(value)
    return false unless value.is_a?(String) && value.match?(SQLITE_UTC) && valid_calendar_date?(value[0, 10])

    Time.iso8601("#{value.tr(" ", "T")}Z")
    true
  rescue ArgumentError
    false
  end
  private_class_method :sqlite_utc?

  def self.valid_calendar_date?(text)
    year, month, day = text.split("-", 3).map { |part| Integer(part, 10) }
    Date.valid_date?(year, month, day)
  rescue ArgumentError, TypeError
    false
  end
  private_class_method :valid_calendar_date?
end

if $PROGRAM_NAME == __FILE__
  unless ARGV.length == 2
    warn "usage: verify_d1_export_manifest.rb MANIFEST EXPORT_SQL"
    exit 2
  end

  begin
    puts JSON.generate(D1ExportManifest.verify(*ARGV))
  rescue ArgumentError => e
    warn e.message
    exit 1
  end
end
