#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

rakkan_root="$(cd "$(dirname "$0")/.." && pwd)"
database_path="${1:-${rakkan_root}/db/rakkan.sqlite}"
normalization_sql="${rakkan_root}/db/normalize_rubygems_weekly_snapshots.sql"

expected_weeks="$(
  sqlite3 "${database_path}" \
    "SELECT COUNT(DISTINCT date(s.taken_on, '-' || ((CAST(strftime('%w', s.taken_on) AS INTEGER) + 6) % 7) || ' days')) FROM adoption_snapshots s INNER JOIN registries r ON r.id = s.registry_id WHERE r.name = 'rubygems';"
)"

sqlite3 "${database_path}" <<SQL
.bail on
BEGIN IMMEDIATE;
.read ${normalization_sql}
COMMIT;
SQL

actual_rows="$(
  sqlite3 "${database_path}" \
    "SELECT COUNT(*) FROM adoption_snapshots s INNER JOIN registries r ON r.id = s.registry_id WHERE r.name = 'rubygems';"
)"
off_cadence_rows="$(
  sqlite3 "${database_path}" \
    "SELECT COUNT(*) FROM adoption_snapshots s INNER JOIN registries r ON r.id = s.registry_id WHERE r.name = 'rubygems' AND strftime('%w', s.taken_on) <> '1';"
)"
foreign_key_violations="$(sqlite3 "${database_path}" "PRAGMA foreign_key_check;")"

if (( expected_weeks > 0 && actual_rows == 0 )); then
  echo "RubyGems snapshot normalization produced no rows" >&2
  exit 1
fi
if (( actual_rows != expected_weeks )); then
  echo "RubyGems snapshot normalization changed ${expected_weeks} weeks into ${actual_rows} rows" >&2
  exit 1
fi
if (( off_cadence_rows != 0 )); then
  echo "RubyGems snapshot normalization left ${off_cadence_rows} rows off Monday" >&2
  exit 1
fi
if [[ -n "${foreign_key_violations}" ]]; then
  echo "RubyGems snapshot normalization introduced foreign-key violations" >&2
  exit 1
fi
