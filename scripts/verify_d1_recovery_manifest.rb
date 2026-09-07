# frozen_string_literal: true

require "date"
require "digest"
require "json"
require "time"

class D1RecoveryManifest
  KEYS = %w[backup_sha256 bookmark counts created_at database generated_at schema_version version].freeze
  COUNT_KEYS = %w[adoption_snapshots package_versions packages registries].freeze
  BOOKMARK = /\A[0-9a-f]{8}-[0-9a-f]{8}-[0-9a-f]{8}-[0-9a-f]{32}\z/
  SQLITE_UTC = /\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d{1,6})?\z/
  SHA256 = /\A[0-9a-f]{64}\z/

  def self.verify(manifest_path, backup_path)
    [manifest_path, backup_path].each do |path|
      stat = File.lstat(path)
      next if stat.file? && !stat.symlink?

      raise ArgumentError, "artifact file must be regular and not a symlink: #{path}"
    end
    raise ArgumentError, "recovery manifest is too large" if File.size(manifest_path) > 65_536

    document = JSON.parse(File.read(manifest_path, encoding: "UTF-8"))
    unless document.is_a?(Hash) && document.keys.sort == KEYS && document["version"] == 1 &&
           document["database"] == "rakkan"
      raise ArgumentError, "recovery manifest has an unknown shape or version"
    end
    unless document["bookmark"].is_a?(String) && document["bookmark"].match?(BOOKMARK)
      raise ArgumentError, "recovery manifest has an invalid D1 bookmark"
    end
    unless document["schema_version"].is_a?(Integer) && document["schema_version"].positive?
      raise ArgumentError, "recovery manifest has an invalid schema version"
    end
    unless sqlite_utc?(document["generated_at"])
      raise ArgumentError, "recovery manifest has an invalid export generation timestamp"
    end
    unless canonical_utc_instant?(document["created_at"])
      raise ArgumentError, "recovery manifest has a noncanonical UTC creation time"
    end

    counts = document["counts"]
    valid_counts = counts.is_a?(Hash) && counts.keys.sort == COUNT_KEYS &&
                   counts.values.all? { |value| value.is_a?(Integer) && value.positive? }
    raise ArgumentError, "recovery manifest must contain positive exact table counts" unless valid_counts

    expected_hash = document["backup_sha256"]
    unless expected_hash.is_a?(String) && expected_hash.match?(SHA256) &&
           Digest::SHA256.file(backup_path).hexdigest == expected_hash
      raise ArgumentError, "recovery SQL checksum does not match the manifest"
    end

    document
  rescue Errno::ENOENT, JSON::ParserError => e
    raise ArgumentError, "invalid recovery artifact: #{e.message}"
  end

  # Time.iso8601 normalizes calendar-impossible days (February 30 parses as
  # March 2), so the calendar date is checked before the time-of-day parse.
  def self.sqlite_utc?(value)
    return false unless value.is_a?(String) && value.match?(SQLITE_UTC) && valid_calendar_date?(value[0, 10])

    Time.iso8601("#{value.tr(" ", "T")}Z")
    true
  rescue ArgumentError
    false
  end
  private_class_method :sqlite_utc?

  def self.canonical_utc_instant?(value)
    return false unless value.is_a?(String) && valid_calendar_date?(value[0, 10])

    parsed = Time.iso8601(value)
    parsed.utc? && parsed.iso8601 == value
  rescue ArgumentError
    false
  end
  private_class_method :canonical_utc_instant?

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
    warn "usage: verify_d1_recovery_manifest.rb MANIFEST BACKUP_SQL"
    exit 2
  end

  begin
    puts JSON.generate(D1RecoveryManifest.verify(*ARGV))
  rescue ArgumentError => e
    warn e.message
    exit 1
  end
end
