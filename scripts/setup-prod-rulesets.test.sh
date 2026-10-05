#!/usr/bin/env bash
# End-to-end tests for setup-prod-rulesets.sh against a stub `gh`, so nothing
# reaches GitHub. The stub logs every call and saves each ruleset body it is
# sent, by repo. Not wired into CI or pre-commit. Run by hand after touching
# the script or deploy-targets.sh:
#   scripts/setup-prod-rulesets.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin"

REPO="$WORK/repo"
mkdir -p "$REPO/scripts"
cp "$SCRIPT_DIR"/deploy-targets.sh "$SCRIPT_DIR"/github-environment.sh "$SCRIPT_DIR"/setup-prod-rulesets.sh "$REPO/scripts/"
export STUB_LOG="$WORK/calls.log" STUB_BODIES="$WORK/bodies"

# gh: logs its arguments and copies an --input file to $STUB_BODIES/<repo>.json.
# A rulesets listing prints id 7 when $STUB_EXISTING is set, and nothing
# otherwise.
cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >>"$STUB_LOG"
input="" path=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --input) input="$2"; shift ;;
    repos/*) path="$1" ;;
    esac
    shift
done
if [ -n "$input" ]; then
    repo="${path#repos/DevelopmentFinanceObservatory/}"
    mkdir -p "$STUB_BODIES"
    cp "$input" "$STUB_BODIES/${repo%%/*}.json"
fi
case "$path" in
*/rulesets) [ -n "${STUB_EXISTING:-}" ] && echo 7 ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
[ "$(command -v gh)" = "$WORK/bin/gh" ] || { echo "gh stub not first on PATH" >&2; exit 1; }

failures=0

run() {
    : >"$STUB_LOG"
    rm -rf "$STUB_BODIES"
    set +e
    out="$("$REPO/scripts/setup-prod-rulesets.sh" "$@" 2>&1 </dev/null)"
    status=$?
    set -e
    calls="$(cat "$STUB_LOG")"
}

check() {
    local label="$1" ok="$2"
    if [ "$ok" = true ]; then
        echo "ok: $label"
    else
        echo "FAIL: $label"
        printf '%s\n' "$out" | sed 's/^/    out: /'
        printf '%s\n' "$calls" | sed 's/^/    log: /'
        failures=$((failures + 1))
    fi
}
is() { [ "$1" = "$2" ] && echo true || echo false; }
has() { [[ "$calls" == *"$1"* ]] && echo true || echo false; }
lacks() { [[ "$calls" != *"$1"* ]] && echo true || echo false; }
count() { grep -cE -e "$1" "$STUB_LOG" || true; }
body() { jq -c "$2" "$STUB_BODIES/$1.json"; }
ten="infra dcp apis ai website pipelines docs ontology spec-kit skills"

# 1. No ruleset yet: each repo gets write for release and a new main ruleset.
run
check "fresh exits 0" "$(is "$status" 0)"
covered=0
for name in $ten; do
    slug="DevelopmentFinanceObservatory/$name"
    check "fresh gives release write on $name" "$(has "gh api --method PUT orgs/DevelopmentFinanceObservatory/teams/release/repos/$slug -f permission=push")"
    check "fresh creates the ruleset on $name" "$(has "gh api --method POST repos/$slug/rulesets --input")"
    check "$name ruleset has no bypass actors" "$(is "$(body "$name" '.bypass_actors')" '[]')"
    check "$name ruleset targets the default branch" "$(is "$(body "$name" '.conditions.ref_name.include')" '["~DEFAULT_BRANCH"]')"
    check "$name ruleset allows merge commits only" "$(is "$(body "$name" '.rules[] | select(.type == "pull_request") | .parameters.allowed_merge_methods')" '["merge"]')"
    check "$name ruleset needs one approval" "$(is "$(body "$name" '.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count')" 1)"
    check "$name ruleset is strict" "$(is "$(body "$name" '.rules[] | select(.type == "required_status_checks") | .parameters.strict_required_status_checks_policy')" true)"
    covered=$((covered + 1))
done
check "fresh covered 10 repos (covered $covered)" "$(is "$covered" 10)"
check "fresh makes 10 team grants and 10 creates" "$(is "$(count '--method (PUT|POST)')" 20)"
check "fresh replaces nothing" "$(lacks '/rulesets/7')"
check "infra requires its three checks from any source" "$(is "$(body infra '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]]')" '[{"context":"sync-guard"},{"context":"terraform fmt check"},{"context":"Prod changed stacks planned"}]')"
check "apis requires sync-guard alone" "$(is "$(body apis '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]]')" '[{"context":"sync-guard"}]')"

# 2. An existing main ruleset is replaced in place.
STUB_EXISTING=1 run
check "existing exits 0" "$(is "$status" 0)"
check "existing replaces infra's ruleset" "$(has "gh api --method PUT repos/DevelopmentFinanceObservatory/infra/rulesets/7 --input")"
check "existing creates none" "$(lacks '--method POST')"
check "existing replaces 10" "$(is "$(count '/rulesets/7 ')" 10)"

# 3. --guard-app-id pins sync-guard alone to that App.
run --guard-app-id 5164144
check "pinned exits 0" "$(is "$status" 0)"
check "pinned infra checks" "$(is "$(body infra '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]]')" '[{"context":"sync-guard","integration_id":5164144},{"context":"terraform fmt check"},{"context":"Prod changed stacks planned"}]')"
check "pinned skills checks" "$(is "$(body skills '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]]')" '[{"context":"sync-guard","integration_id":5164144}]')"

# 4. A non-numeric app id is refused before any gh call.
run --guard-app-id dfo-release
check "bad app id exits 1" "$(is "$status" 1)"
check "bad app id makes no gh call" "$(is "$calls" "")"

# 5. --dry-run reads the rulesets and writes nothing.
run --dry-run
check "dry run exits 0" "$(is "$status" 0)"
check "dry run makes no write" "$(lacks '--method')"
check "dry run reads every repo's rulesets" "$(is "$(count '^gh api repos/[^ ]+/rulesets ')" 10)"
check "dry run prints the creates" "$([[ "$out" == *"DRY-RUN: gh api --method POST repos/DevelopmentFinanceObservatory/infra/rulesets"* ]] && echo true || echo false)"

if [ "$failures" -eq 0 ]; then
    echo "All scenarios passed."
else
    echo "$failures check(s) failed."
    exit 1
fi
