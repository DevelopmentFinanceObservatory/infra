#!/usr/bin/env bash
# Runs one Terraform command in a CI step and keeps its output for the comment
# scripts. stdout streams to the job log and is copied to <dir>/<name>.stdout.
# stderr goes to <dir>/<name>.stderr and is printed once the command ends.
# <dir> is $TF_OUTPUT_DIR, else $RUNNER_TEMP/tf-output, and
# .github/scripts/tf-output.js reads it. The output travels in files because
# Linux caps one environment variable at 128 KiB, and a plan of a stack's first
# apply can pass that.
#
# Usage: tf-capture.sh <name> <command> [args...]
# Exit:  the command's own exit code.
set -uo pipefail

name=${1:?usage: tf-capture.sh <name> <command> [args...]}
shift
dir=${TF_OUTPUT_DIR:-${RUNNER_TEMP:?RUNNER_TEMP is unset}/tf-output}
mkdir -p "$dir"

"$@" 2>"$dir/$name.stderr" | tee "$dir/$name.stdout"
code=${PIPESTATUS[0]}
cat "$dir/$name.stderr" >&2
exit "$code"
