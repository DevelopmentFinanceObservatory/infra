#!/usr/bin/env bash
# Scenario tests for plan-changes-sha256.sh against a stub `terraform` that
# prints $STUB_PLAN as the plan's JSON, or fails when it is empty. Nothing
# runs it automatically; run it by hand after touching the script:
#   scripts/plan-changes-sha256.test.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/plan-changes-sha256.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin"
cat >"$WORK/bin/terraform" <<'STUB'
#!/usr/bin/env bash
[ -n "$STUB_PLAN" ] || { echo "stub: no plan" >&2; exit 1; }
printf '%s\n' "$STUB_PLAN"
STUB
chmod +x "$WORK/bin/terraform"
export PATH="$WORK/bin:$PATH"

failures=0
check() {
    if [ "$2" = true ]; then echo "ok: $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi
}
hash_of() { STUB_PLAN="$1" "$SCRIPT" tfplan; }

# plan <job last_complete> <job filter> <ruleset last_updated>: a plan that
# updates the Logpush job's filter and leaves the custom fields ruleset as it
# is, with the computed values a refresh moves between two plans.
plan() {
    cat <<JSON
{"resource_changes": [
  {"address": "cloudflare_logpush_job.dataset_reads[0]", "change": {"actions": ["update"],
    "before": {"filter": "old", "last_complete": "$1", "enabled": true},
    "after": {"filter": "$2", "last_complete": "$1", "enabled": true},
    "after_unknown": {}}},
  {"address": "cloudflare_ruleset.log_custom_fields[0]", "change": {"actions": ["no-op"],
    "before": {"last_updated": "$3"}, "after": {"last_updated": "$3"}, "after_unknown": {}}}
],
"output_changes": {"job_id": {"actions": ["no-op"], "before": 7, "after": 7}}}
JSON
}

reviewed="$(hash_of "$(plan 2026-11-19T10:00:00Z new 2026-11-18T09:00:00Z)")"
check "a hash is 64 hex characters" "$([[ "$reviewed" =~ ^[0-9a-f]{64}$ ]] && echo true || echo false)"
later="$(hash_of "$(plan 2026-11-19T10:05:00Z new 2026-11-19T10:04:00Z)")"
check "computed values that move between plans keep the hash" "$([ "$later" = "$reviewed" ] && echo true || echo false)"
other="$(hash_of "$(plan 2026-11-19T10:00:00Z newer 2026-11-18T09:00:00Z)")"
check "a different planned value changes the hash" "$([ "$other" != "$reviewed" ] && echo true || echo false)"

set +e
out="$(STUB_PLAN="" "$SCRIPT" tfplan 2>/dev/null)"
code=$?
set -e
check "a failed terraform show exits non-zero with no hash" "$([ "$code" -ne 0 ] && [ -z "$out" ] && echo true || echo false)"
set +e
"$SCRIPT" >/dev/null 2>&1
code=$?
set -e
check "no arguments exits 2" "$([ "$code" -eq 2 ] && echo true || echo false)"

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed."
    exit 1
fi
echo "All checks passed."
