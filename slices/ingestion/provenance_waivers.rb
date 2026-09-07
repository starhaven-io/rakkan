# frozen_string_literal: true

require "date"
require "json"

module Ingestion
  # Exact, time-bounded exceptions for registry versions whose provenance
  # endpoint persistently returns 404. Entries are source-controlled so a
  # missing version can stop blocking publication without becoming a false
  # negative observation.
  class ProvenanceWaivers
    Entry = Data.define(:registry, :package, :number, :platform, :reason, :expires_on)

    DOCUMENT_KEYS = %w[version waivers].freeze
    ENTRY_KEYS = %w[expires_on number package platform reason registry].freeze
    MAX_ENTRIES = 100
    WILDCARD_PATTERN = /[*?\[\]{}%]/

    def self.load(path: Hanami.app.root.join("config", "provenance_not_found_waivers.json"),
                  today: Time.now.utc.to_date)
      document = JSON.parse(File.read(path, encoding: "UTF-8"))
      unless document.is_a?(Hash) && document.keys.sort == DOCUMENT_KEYS && document["version"] == 1
        raise ArgumentError, "provenance waiver document must contain only version 1 and waivers"
      end

      raw_entries = document["waivers"]
      unless raw_entries.is_a?(Array) && raw_entries.length <= MAX_ENTRIES
        raise ArgumentError, "provenance waivers must be an array of at most #{MAX_ENTRIES} entries"
      end

      parsed_entries = raw_entries.map.with_index do |entry, index|
        parse_entry(entry, index:)
      end
      identities = parsed_entries.map { |entry| identity(entry) }
      unique_identities = identities.uniq.length == identities.length
      raise ArgumentError, "provenance waiver identities must be unique" unless unique_identities

      active_entries = parsed_entries.reject do |entry|
        expired = entry.expires_on < today
        warn_expired(entry) if expired
        expired
      end
      new(active_entries)
    rescue JSON::ParserError => e
      raise ArgumentError, "invalid provenance waiver JSON: #{e.message}"
    end

    def self.parse_entry(entry, index:)
      unless entry.is_a?(Hash) && entry.keys.sort == ENTRY_KEYS
        raise ArgumentError, "provenance waiver #{index} has unexpected fields"
      end

      values = ENTRY_KEYS.to_h { |key| [key, entry[key]] }
      raise ArgumentError, "provenance waiver #{index} fields must all be strings" unless values.values.all?(String)

      unless values["registry"].match?(/\A[a-z0-9][a-z0-9_-]*\z/) &&
             values["package"].match?(/\A\S+\z/) && values["number"].match?(/\A\S+\z/) &&
             values["platform"].match?(/\A\S*\z/)
        raise ArgumentError, "provenance waiver #{index} has an invalid exact identity"
      end
      if values.values_at("registry", "package", "number", "platform").any? { |value| value.match?(WILDCARD_PATTERN) }
        raise ArgumentError, "provenance waiver #{index} must not contain wildcard characters"
      end

      reason = values["reason"].strip
      unless reason == values["reason"] && reason.length.between?(1, 300)
        raise ArgumentError, "provenance waiver #{index} must have a concise reason"
      end

      expires_on = Date.iso8601(values["expires_on"])
      unless expires_on.iso8601 == values["expires_on"]
        raise ArgumentError, "provenance waiver #{index} has a noncanonical expiry"
      end

      Entry.new(
        registry: values["registry"], package: values["package"], number: values["number"],
        platform: values["platform"], reason:, expires_on:
      )
    rescue Date::Error
      raise ArgumentError, "provenance waiver #{index} has an invalid expiry"
    end
    private_class_method :parse_entry

    def self.warn_expired(entry)
      warn "ignoring expired provenance waiver: " \
           "#{entry.registry}/#{entry.package}/#{entry.number}/#{entry.platform} " \
           "(expired #{entry.expires_on.iso8601})"
    end
    private_class_method :warn_expired

    def self.identity(entry)
      [entry.registry, entry.package, entry.number, entry.platform]
    end
    private_class_method :identity

    attr_reader :entries

    def initialize(entries)
      @entries = entries.freeze
      @by_identity = entries.to_h do |entry|
        [[entry.registry, entry.package, entry.number, entry.platform], entry]
      end.freeze
    end

    def find(registry:, package:, number:, platform:)
      @by_identity[[registry, package, number, platform]]
    end

    def for_registry(registry)
      entries.select { |entry| entry.registry == registry }
    end
  end
end
