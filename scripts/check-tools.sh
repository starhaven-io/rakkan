#!/usr/bin/env bash

set -euo pipefail

missing=()
for entry in \
  "shellcheck:shellcheck" \
  "actionlint:actionlint" \
  "zizmor:zizmor" \
  "pinprick:pinprick" \
  "typos:typos-cli"; do
  tool="${entry%%:*}"
  package="${entry#*:}"
  if ! command -v "${tool}" >/dev/null 2>&1; then
    missing+=("${tool} (Homebrew package: ${package})")
  fi
done

if ((${#missing[@]} > 0)); then
  echo "Missing tools required by just check:" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 1
fi

echo "All external tools required by just check are available."
