#!/usr/bin/env bash

set -euo pipefail

registry="${REGISTRY:-rubygems}"
refresh_limit="${REFRESH_LIMIT:-250}"
pipeline_date="${PIPELINE_DATE:-$(date -u +%F)}"

if ! [[ "${registry}" =~ ^(rubygems|cratesio|all)$ ]]; then
  echo "registry must be rubygems, cratesio, or all" >&2
  exit 1
fi
if ! [[ "${refresh_limit}" =~ ^[1-9][0-9]{0,3}$ ]] || (( refresh_limit > 1000 )); then
  echo "refresh_limit must be an integer from 1 to 1000" >&2
  exit 1
fi
if ! [[ "${pipeline_date}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "pipeline date must use YYYY-MM-DD" >&2
  exit 1
fi

if [[ "${registry}" == "all" ]]; then
  for registry_name in rubygems cratesio; do
    PIPELINE_DATE="${pipeline_date}" REGISTRY="${registry_name}" bash "$0"
  done
  exit 0
fi

bundle exec ruby "research/check_${registry}_seed_update.rb" --current "seed/${registry}"

bundle exec rake "ingest:seed[${registry}]"
if [[ "${registry}" == "rubygems" ]]; then
  for attempt in 1 2 3; do
    if bundle exec rake "ingest:discover[${registry}]"; then
      break
    fi
    if (( attempt == 3 )); then
      echo "ingest:discover did not drain after ${attempt} attempts" >&2
      exit 1
    fi
    echo "ingest:discover reached its page budget; retrying from its cursor" >&2
  done
fi

refresh_result=""
remaining=""
refresh_errors=""
refresh_waived=""
for attempt in 1 2 3; do
  if refresh_result="$(bundle exec rake "ingest:refresh[${refresh_limit},${registry},${pipeline_date}]")"; then
    printf '%s\n' "${refresh_result}"
    refresh_payload="${refresh_result##*$'\n'}"
    if ! remaining="$(jq -er '.remaining | select(type == "number" and floor == . and . >= 0)' \
        <<< "${refresh_payload}")"; then
      echo "ingest:refresh did not report a valid remaining count" >&2
      exit 1
    fi
    if ! refresh_errors="$(jq -er '.errors | select(type == "number" and floor == . and . >= 0)' \
        <<< "${refresh_payload}")"; then
      echo "ingest:refresh did not report a valid error count" >&2
      exit 1
    fi
    if ! refresh_waived="$(jq -er '.waived | select(type == "number" and floor == . and . >= 0)' \
        <<< "${refresh_payload}")"; then
      echo "ingest:refresh did not report a valid waived count" >&2
      exit 1
    fi
    if (( remaining == 0 && refresh_errors == 0 )); then
      break
    fi
    if (( attempt < 3 )); then
      echo "${registry}: ${remaining} tracked versions remain unchecked (${refresh_errors} errors); continuing" >&2
    fi
    continue
  fi
  if (( attempt == 3 )); then
    echo "ingest:refresh did not complete within its retry budget" >&2
    exit 1
  fi
  echo "ingest:refresh failed; retrying from its persisted checks" >&2
done

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "${registry}: ${remaining} tracked versions remain unchecked"
    echo "${registry}: ${refresh_errors} provenance errors in the final attempt"
    echo "${registry}: ${refresh_waived} exact provenance 404 waivers in the final attempt"
  } >> "${GITHUB_STEP_SUMMARY}"
fi
if (( refresh_errors > 0 )); then
  echo "${registry}: provenance errors remain; refusing to publish a snapshot" >&2
  exit 1
fi
if (( remaining > 0 )); then
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    echo "${registry} refresh remains in progress; publishing durable progress without a snapshot" \
      >> "${GITHUB_STEP_SUMMARY}"
  fi
else
  bundle exec rake "snapshot:take[${registry},${pipeline_date}]"
fi
