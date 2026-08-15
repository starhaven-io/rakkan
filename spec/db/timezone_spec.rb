# frozen_string_literal: true

RSpec.describe "Timestamp round-tripping", :db do
  include SpecSeeding

  # Regression for a real defect: with Sequel's default nil timezones, naive
  # SQLite timestamps hydrate in the process-local zone, shifting every UTC
  # instant by the local offset. Run under a non-UTC zone to prove the fix.
  it "preserves the instant across write and read under a non-UTC TZ" do
    old_tz = ENV.fetch("TZ", nil)
    ENV["TZ"] = "America/Chicago"

    instant = Time.utc(2026, 8, 10, 21, 21, 1)
    registry = create_registry!
    pkg = create_package!(registry, name: "tzcheck")
    create_version!(pkg, number: "1.0.0", published_at: instant)

    row = Hanami.app["relations.package_versions"].where(package_id: pkg.id).one
    expect(row[:published_at].to_time).to eq(instant)
    expect(row[:published_at].to_time.utc_offset).to eq(0)
  ensure
    ENV["TZ"] = old_tz
  end
end
