#!/usr/bin/env bash

set -euo pipefail

if (( $# < 4 )); then
  echo "usage: seed-proposal-needed.sh REGISTRY CANDIDATE_DIR AUTOMATION_BRANCH FILE..." >&2
  exit 2
fi

registry="$1"
candidate_dir="$2"
automation_branch="$3"
shift 3
names=("$@")
repository="${GITHUB_REPOSITORY:-}"

if ! [[ "${registry}" =~ ^[a-z0-9][a-z0-9_-]*$ ]] ||
    [[ "${automation_branch}" != "automation/${registry}-seed" ]] ||
    ! [[ "${repository}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "invalid seed proposal identity" >&2
  exit 2
fi
if [[ ! -d "${candidate_dir}" || -L "${candidate_dir}" ]]; then
  echo "candidate seed directory must be a real directory" >&2
  exit 2
fi

expected_paths=()
for name in "${names[@]}"; do
  if ! [[ "${name}" =~ ^[A-Za-z0-9_.-]+$ ]] ||
      [[ ! -f "${candidate_dir}/${name}" || -L "${candidate_dir}/${name}" ]]; then
    echo "candidate seed file is invalid: ${name}" >&2
    exit 2
  fi
  expected_paths+=("seed/${registry}/${name}")
done
expected_json="$(printf '%s\n' "${expected_paths[@]}" | jq -Rsc 'split("\n") | map(select(length > 0)) | sort')"
required_path="seed/${registry}/manifest.json"

owner="${repository%%/*}"
pull_pages="$(gh api --paginate --slurp --method GET "repos/${repository}/pulls" \
  -f state=open -f base=main -f "head=${owner}:${automation_branch}" -f per_page=100)"
pulls="$(jq -cer --arg repository "${repository}" --arg branch "${automation_branch}" '
  select(type == "array" and all(.[]; type == "array")) |
  [.[][] |
    select(
      .head.repo.full_name == $repository and
      .head.ref == $branch and
      .base.ref == "main"
    ) |
    {number, head_sha: .head.sha}
  ]
' <<< "${pull_pages}")"
pull_count="$(jq -er 'select(type == "array") | length' <<< "${pulls}")"
if (( pull_count == 0 )); then
  printf 'true\n'
  exit 0
fi
if (( pull_count != 1 )); then
  echo "expected at most one open seed proposal, found ${pull_count}" >&2
  exit 1
fi

pull_number="$(jq -er '.[0].number | select(type == "number" and floor == . and . > 0)' <<< "${pulls}")"
head_sha="$(jq -er '.[0].head_sha | select(type == "string" and test("^[0-9a-f]{40}$"))' <<< "${pulls}")"
pull_files="$(gh api --paginate --slurp "repos/${repository}/pulls/${pull_number}/files")"
if ! jq -e --argjson expected "${expected_json}" --arg required "${required_path}" '
    select(type == "array" and all(.[]; type == "array")) |
    [.[][] | {filename, status}] as $files |
    ($files | length) > 0 and
    ($files | map(.filename) | length) == ($files | map(.filename) | unique | length) and
    all($files[]; .status == "modified") and
    all($files[].filename; . as $filename | $expected | index($filename) != null) and
    ($files | map(.filename) | index($required)) != null
  ' <<< "${pull_files}" >/dev/null; then
  echo "open seed proposal contains an unexpected file set" >&2
  exit 1
fi

tree="$(gh api "repos/${repository}/git/trees/${head_sha}?recursive=1")"
jq -e '.truncated == false and (.tree | type == "array")' <<< "${tree}" >/dev/null

for index in "${!names[@]}"; do
  name="${names[index]}"
  path="${expected_paths[index]}"
  remote_sha="$(jq -er --arg path "${path}" '
    [.tree[] | select(.path == $path and .type == "blob") | .sha] |
    select(length == 1) | .[0] | select(test("^[0-9a-f]{40}$"))
  ' <<< "${tree}")"
  local_sha="$(git hash-object --no-filters -- "${candidate_dir}/${name}")"
  if [[ "${local_sha}" != "${remote_sha}" ]]; then
    printf 'true\n'
    exit 0
  fi
done

printf 'false\n'
