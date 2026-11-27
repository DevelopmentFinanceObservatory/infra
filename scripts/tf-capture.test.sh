#!/usr/bin/env bash
# Test that a removed member is absent from the log and the comment inputs.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export TF_OUTPUT_DIR="$work/capture"

status=0
bash "$script_dir/tf-capture.sh" plan bash -c '
  echo "eval_runs_viewers[\"former-viewer\"]: Refreshing state... [id=bucket/roles/storage.objectViewer/user:former.viewer@example.org]"
  echo "Error: buckets/bucket/roles/storage.objectViewer/GROUP%3AFormer%2BTeam%40example.org" >&2
  echo "Writer: serviceAccount:runner@example.org"
  exit 2
' >"$work/stdout" 2>"$work/stderr" || status=$?

[[ "$status" -eq 2 ]]
cmp "$work/stdout" "$TF_OUTPUT_DIR/plan.stdout"
cmp "$work/stderr" "$TF_OUTPUT_DIR/plan.stderr"
grep -Fq 'eval_runs_viewers["former-viewer"]: Refreshing state... [id=bucket/roles/storage.objectViewer/***]' "$work/stdout"
grep -Fq 'Error: buckets/bucket/roles/storage.objectViewer/***' "$work/stderr"
grep -Fq 'Writer: serviceAccount:runner@example.org' "$work/stdout"
[[ -z "$(find "$TF_OUTPUT_DIR" -name '.stderr.*' -print)" ]]
echo "Terraform capture redaction checks passed."
