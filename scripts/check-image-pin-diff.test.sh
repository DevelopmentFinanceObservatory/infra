#!/usr/bin/env bash
# Scenario tests for check-image-pin-diff.sh. Not wired into CI or
# pre-commit: this validator only ever runs against real PR commits in
# dfo-infra's own history, and a synthetic git repo is the only way to
# exercise its exit codes deterministically. Run by hand after touching the
# script:
#   scripts/check-image-pin-diff.test.sh
#
# Each scenario builds a throwaway git repo under a temp directory with the
# same PIN_FILE path the script hard-codes, commits a "before" and "after"
# state, and asserts the script's exit code (and, for the one success case,
# its stdout) against what that diff shape should produce.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/check-image-pin-diff.sh"
PIN_FILE="infra/dfo-dev/dcp/image.auto.tfvars"

# Two otherwise-valid pin values, distinct only in the digest, so scenarios
# can express "the pin bumped" without every scenario inventing its own.
HEX_A="$(printf 'a%.0s' $(seq 1 64))"
HEX_B="$(printf 'b%.0s' $(seq 1 64))"
VALUE_A="northamerica-northeast1-docker.pkg.dev/dev-fin-observatory/datacommons/dfo-services-image@sha256:${HEX_A}"
VALUE_B="northamerica-northeast1-docker.pkg.dev/dev-fin-observatory/datacommons/dfo-services-image@sha256:${HEX_B}"

failures=0
stderr_file="$(mktemp)"
trap 'rm -f "$stderr_file"' EXIT

# make_repo builds a fresh git repo under a new temp dir, writes PIN_FILE
# with $1 as the assignment's value, and commits it as the "base" state.
# Echoes the repo's path so the caller can chain further commits onto it.
make_repo() {
  local value="$1" dir
  dir="$(mktemp -d)"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@example.invalid"
  git -C "$dir" config user.name "check-image-pin-diff tests"
  mkdir -p "$dir/$(dirname "$PIN_FILE")"
  printf 'datacommons_services_image = "%s"\n' "$value" >"$dir/$PIN_FILE"
  git -C "$dir" add "$PIN_FILE"
  git -C "$dir" commit -q -m base
  echo "$dir"
}

# run_case dir expected_exit description. Commits whatever the working tree
# currently holds in $dir as the "head" state, runs the script against base
# and head, and compares its exit code to $expected_exit. Leaves the
# script's stdout in $LAST_CASE_STDOUT, since a bash return code can't carry
# an image string.
LAST_CASE_STDOUT=""
run_case() {
  local dir="$1" expected="$2" description="$3" base head actual_exit err
  base="$(git -C "$dir" rev-parse HEAD)"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m head
  head="$(git -C "$dir" rev-parse HEAD)"

  set +e
  LAST_CASE_STDOUT="$(cd "$dir" && "$SCRIPT" "$base" "$head" 2>"$stderr_file")"
  actual_exit=$?
  set -e
  err="$(cat "$stderr_file")"

  if [ "$actual_exit" -eq "$expected" ]; then
    echo "ok   - $description (exit $actual_exit)"
  else
    echo "FAIL - $description: expected exit $expected, got $actual_exit"
    echo "       stdout: $LAST_CASE_STDOUT"
    echo "       stderr: $err"
    failures=$((failures + 1))
  fi
}

# 1. A clean, single-line pin bump to a valid digest: exit 0, and the new
# value on stdout.
dir="$(make_repo "$VALUE_A")"
printf 'datacommons_services_image = "%s"\n' "$VALUE_B" >"$dir/$PIN_FILE"
run_case "$dir" 0 "single-line pin bump"
if [ "$LAST_CASE_STDOUT" != "$VALUE_B" ]; then
  echo "FAIL - single-line pin bump: expected stdout '$VALUE_B', got '$LAST_CASE_STDOUT'"
  failures=$((failures + 1))
fi
rm -rf "$dir"

# 2. The pin bump plus an unrelated second file touched in the same diff:
# exit 10 (diff touches more than PIN_FILE).
dir="$(make_repo "$VALUE_A")"
printf 'datacommons_services_image = "%s"\n' "$VALUE_B" >"$dir/$PIN_FILE"
echo "unrelated" >"$dir/other-file.txt"
run_case "$dir" 10 "pin bump plus a second changed file"
rm -rf "$dir"

# 3. The pin bumps and a blank line is appended to the same file in the
# same diff. A blank added/removed line looks like "one line changed" to a
# naive +/- filter, so this has to fail as a single-line change (exit 11),
# not pass as a clean pin bump.
dir="$(make_repo "$VALUE_A")"
printf 'datacommons_services_image = "%s"\n\n' "$VALUE_B" >"$dir/$PIN_FILE"
run_case "$dir" 11 "pin bump plus an appended blank line (regression case)"
rm -rf "$dir"

# 4. The pin bump plus a second, non-blank line changed in the same file
# (a comment edit): exit 11, the non-empty-line analogue of case 3.
dir="$(make_repo "$VALUE_A")"
{
  printf 'datacommons_services_image = "%s"\n' "$VALUE_B"
  echo "# an added comment"
} >"$dir/$PIN_FILE"
run_case "$dir" 11 "pin bump plus a second changed line"
rm -rf "$dir"

# 5. A new value that's well-formed as an assignment but still a tag, not a
# digest: exit 12.
dir="$(make_repo "$VALUE_A")"
printf 'datacommons_services_image = "%s"\n' "northamerica-northeast1-docker.pkg.dev/dev-fin-observatory/datacommons/dfo-services-image:dfo-dev-deadbeef" >"$dir/$PIN_FILE"
run_case "$dir" 12 "tag-form value now rejected"
rm -rf "$dir"

# 6. A new value shaped like a digest pin but with a short digest: exit 12.
dir="$(make_repo "$VALUE_A")"
printf 'datacommons_services_image = "%s"\n' "northamerica-northeast1-docker.pkg.dev/dev-fin-observatory/datacommons/dfo-services-image@sha256:deadbeef" >"$dir/$PIN_FILE"
run_case "$dir" 12 "short digest rejected"
rm -rf "$dir"

if [ "$failures" -eq 0 ]; then
  echo "All scenarios passed."
  exit 0
else
  echo "$failures scenario(s) failed."
  exit 1
fi
