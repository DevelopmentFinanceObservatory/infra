#!/usr/bin/env bash
# Runs one Terraform command in a CI step and keeps its output for the comment
# scripts. Redacted stdout streams to the job log and to <dir>/<name>.stdout.
# Redacted stderr goes to <dir>/<name>.stderr and prints after the command.
# <dir> is $TF_OUTPUT_DIR, else $RUNNER_TEMP/tf-output, and
# .github/scripts/tf-output.js reads it. The output travels in files because
# Linux caps one environment variable at 128 KiB, and a plan of a stack's first
# apply can pass that.
#
# Usage: tf-capture.sh <name> <command> [args...]
# Exit:  the command's own exit code, or 1 if capture fails.
set -uo pipefail

name=${1:?usage: tf-capture.sh <name> <command> [args...]}
shift
dir=${TF_OUTPUT_DIR:-${RUNNER_TEMP:?RUNNER_TEMP is unset}/tf-output}
mkdir -p "$dir" || exit 1

# Existing IAM IDs can name people removed from the latest principals secret,
# so the Actions mask list may not include them. Filter both streams before
# either goes to a public log or a file the PR comment reads.
redact_iam_members() {
  LC_ALL=C sed -E 's/(user|group)(:|%3a)([a-z0-9._+-]|%[0-9a-f]{2})+(@|%40)[a-z0-9.-]+/***/gI'
}

raw_stderr=$(mktemp "$dir/.stderr.XXXXXX") || exit 1
trap 'rm -f "$raw_stderr"' EXIT

"$@" 2>"$raw_stderr" | redact_iam_members | tee "$dir/$name.stdout"
statuses=("${PIPESTATUS[@]}")
if (( statuses[1] != 0 || statuses[2] != 0 )); then
  exit 1
fi
redact_iam_members <"$raw_stderr" >"$dir/$name.stderr" || exit 1
cat "$dir/$name.stderr" >&2 || exit 1
exit "${statuses[0]}"
