#!/usr/bin/env bash
# Tests for bootstrap-principals.sh against a stub `gcloud`, so nothing
# reaches GCP. The stub logs every call; the cases check that each secret
# name suffix accepts its own schema, refuses every malformed file before any
# gcloud call, and never echoes a value from the file. Not wired into CI or
# pre-commit. Run by hand after touching the script:
#   scripts/bootstrap-principals.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin"
export STUB_LOG="$WORK/calls.log"

# gcloud: logs its arguments. `secrets describe` fails, as for a new secret;
# every other call succeeds.
cat >"$WORK/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "gcloud $*" >>"$STUB_LOG"
[ "$1 $2" = "secrets describe" ] && exit 1
exit 0
STUB
chmod +x "$WORK/bin/gcloud"
export PATH="$WORK/bin:$PATH"

failures=0
cases=0

# run <project> <secret> <json>: runs the script on <json>, setting $status,
# $out (stdout and stderr) and $calls.
run() {
    : >"$STUB_LOG"
    printf '%s' "$3" >"$WORK/principals.json"
    status=0
    out=$("$SCRIPT_DIR/bootstrap-principals.sh" "$1" "$2" "$WORK/principals.json" 2>&1) || status=$?
    calls=$(cat "$STUB_LOG")
}

check() {
    cases=$((cases + 1))
    if [ "$2" = true ]; then
        echo "ok   $1"
    else
        echo "FAIL $1"
        printf '  output: %s\n  calls: %s\n' "$out" "$calls"
        failures=$((failures + 1))
    fi
}

is() { [ "$1" = "$2" ] && echo true || echo false; }
says() { [[ "$out" == *"$1"* ]] && echo true || echo false; }

# accepts <label> <secret> <json>: the file is written as the latest version.
accepts() {
    run test-project "$2" "$3"
    check "$1 is accepted" "$(is "$status" 0)"
    check "$1 adds a version" "$([[ "$calls" == *"secrets versions add $2 --project=test-project"* ]] && echo true || echo false)"
}

# refuses <label> <secret> <json> <message>: exits 1 naming <message>, makes
# no gcloud call, and prints no address from the file.
refuses() {
    run test-project "$2" "$3"
    check "$1 is refused" "$(is "$status" 1)"
    check "$1 names the problem" "$(says "$4")"
    check "$1 makes no gcloud call" "$(is "$calls" "")"
    check "$1 prints no address" "$([[ "$out" != *example.org* ]] && echo true || echo false)"
}

F=dfo-test-foundation-principals
A=dfo-test-ai-principals
T=dfo-test-telemetry-principals
G='"group:a@example.org"'
G2='"group:b@example.org"'

accepts "foundation" "$F" "{\"applier_impersonators\": {\"appliers\": $G}, \"ingestion_operators\": {}, \"budget_alerts\": {}}"
refuses "foundation missing key" "$F" "{\"applier_impersonators\": {}}" "missing top-level key ingestion_operators"
refuses "foundation extra key" "$F" "{\"applier_impersonators\": {}, \"ingestion_operators\": {}, \"budget_alerts\": {}, \"readers\": {}}" "unexpected top-level key readers"
refuses "foundation bare address" "$F" "{\"applier_impersonators\": {\"x\": \"a@example.org\"}, \"ingestion_operators\": {}, \"budget_alerts\": {}}" "each applier_impersonators value must be"
refuses "foundation duplicate member" "$F" "{\"applier_impersonators\": {}, \"ingestion_operators\": {\"x\": $G, \"y\": $G}, \"budget_alerts\": {}}" "ingestion_operators holds the same value under two labels"
refuses "foundation address as label" "$F" "{\"applier_impersonators\": {\"a@example.org\": $G}, \"ingestion_operators\": {}, \"budget_alerts\": {}}" "applier_impersonators has a label outside"
refuses "foundation non-object member list" "$F" "{\"applier_impersonators\": [$G], \"ingestion_operators\": {}, \"budget_alerts\": {}}" "applier_impersonators must be an object"
accepts "foundation with budget alerts" "$F" "{\"applier_impersonators\": {}, \"ingestion_operators\": {}, \"budget_alerts\": {\"finance\": \"a@example.org\"}}"
refuses "foundation missing budget_alerts" "$F" '{"applier_impersonators": {}, "ingestion_operators": {}}' "missing top-level key budget_alerts"
refuses "foundation prefixed budget alert" "$F" "{\"applier_impersonators\": {}, \"ingestion_operators\": {}, \"budget_alerts\": {\"x\": $G}}" "each budget_alerts value must be a bare email address"
refuses "foundation duplicate budget alert" "$F" '{"applier_impersonators": {}, "ingestion_operators": {}, "budget_alerts": {"x": "a@example.org", "y": "a@example.org"}}' "budget_alerts holds the same value"
refuses "telemetry file to foundation" "$F" "{\"readers\": {\"x\": $G}, \"alerts\": {\"x\": \"a@example.org\"}}" "missing top-level key applier_impersonators"

accepts "ai" "$A" "{\"studio_token_readers\": {\"testers\": $G}, \"mcp_token_readers\": {}}"
accepts "ai with both empty" "$A" '{"studio_token_readers": {}, "mcp_token_readers": {}}'
refuses "ai missing key" "$A" "{\"studio_token_readers\": {\"testers\": $G}}" "missing top-level key mcp_token_readers"
refuses "ai unknown prefix" "$A" "{\"studio_token_readers\": {\"x\": \"team:a@example.org\"}, \"mcp_token_readers\": {}}" "each studio_token_readers value must be"
refuses "ai non-string member" "$A" '{"studio_token_readers": {"x": 1}, "mcp_token_readers": {}}' "each studio_token_readers value must be"
refuses "ai duplicate member" "$A" "{\"studio_token_readers\": {}, \"mcp_token_readers\": {\"x\": $G, \"y\": $G}}" "mcp_token_readers holds the same value"

accepts "telemetry" "$T" "{\"readers\": {\"x\": $G, \"y\": $G2}, \"alerts\": {\"x\": \"a@example.org\"}}"
refuses "telemetry missing readers" "$T" '{"alerts": {"x": "a@example.org"}}' "missing top-level key readers"
refuses "telemetry empty alerts" "$T" "{\"readers\": {\"x\": $G}, \"alerts\": {}}" "alerts must hold at least 1 entry"
refuses "telemetry prefixed alert" "$T" "{\"readers\": {}, \"alerts\": {\"x\": $G}}" "each alerts value must be a bare email address"
refuses "telemetry reader with no prefix" "$T" '{"readers": {"x": "a@example.org"}, "alerts": {"x": "b@example.org"}}' "each readers value must be"
refuses "telemetry duplicate alert" "$T" '{"readers": {}, "alerts": {"x": "a@example.org", "y": "a@example.org"}}' "alerts holds the same value"

refuses "unknown suffix" dfo-test-website-principals '{}' "has no schema"
refuses "invalid JSON" "$F" '{"applier_impersonators": ' "is not valid JSON"
refuses "top-level array" "$F" '[]' "must hold a JSON object"
run Bad_Project "$F" '{"applier_impersonators": {}, "ingestion_operators": {}, "budget_alerts": {}}'
check "bad project id is refused" "$(is "$status" 1)"
check "bad project id names the problem" "$(says 'is not a GCP project id')"
check "bad project id makes no gcloud call" "$(is "$calls" "")"

[ "$cases" -gt 0 ] || { echo "no cases ran"; exit 1; }
if [ "$failures" -eq 0 ]; then
    echo "All $cases checks passed."
    exit 0
else
    echo "$failures of $cases check(s) failed."
    exit 1
fi
