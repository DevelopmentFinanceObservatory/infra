#!/usr/bin/env bash
# Tests for bootstrap-principals.sh against a stub `gcloud`, so nothing
# reaches GCP. The stub logs every call; the cases check that each secret
# name suffix accepts its own schema, refuses every malformed file before any
# gcloud call, and never echoes a value from the file.
#
# With terraform on PATH, the parity section then feeds every schema case to
# infra/modules/principals-secret under `terraform test` with a mocked
# provider, both reading the stack's schema from the module's schemas.json:
# what the script wrote for an accepted case, and the raw file or its
# canonical form for a refused one. The module must accept and refuse the same cases. Its init
# downloads the google provider, so set TF_PLUGIN_CACHE_DIR to reuse one.
#
# Not wired into CI or pre-commit. Run by hand after touching the script or
# the module:
#   scripts/bootstrap-principals.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin" "$WORK/parity"
export STUB_LOG="$WORK/calls.log" STUB_WRITTEN="$WORK/written.json"

# gcloud: logs its arguments and copies the file `versions add` sends.
# `secrets describe` fails, as for a new secret; every other call succeeds.
cat >"$WORK/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "gcloud $*" >>"$STUB_LOG"
[ "$1 $2" = "secrets describe" ] && exit 1
for a in "$@"; do case "$a" in --data-file=*) cp "${a#--data-file=}" "$STUB_WRITTEN" ;; esac; done
exit 0
STUB
chmod +x "$WORK/bin/gcloud"
export PATH="$WORK/bin:$PATH"

failures=0
cases=0
parity_cases=0

# run <project> <secret> <json>: runs the script on <json>, setting $status,
# $out (stdout and stderr) and $calls.
run() {
    : >"$STUB_LOG"
    rm -f "$STUB_WRITTEN"
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

# keep <verdict> <secret> <file>: saves a case for the parity section.
keep() {
    parity_cases=$((parity_cases + 1))
    cp "$3" "$WORK/parity/$parity_cases.json"
    printf '%s %s\n' "$1" "$2" >"$WORK/parity/$parity_cases.case"
}

# accepts <label> <secret> <json>: the canonical form of the file is written
# as the latest version.
accepts() {
    run test-project "$2" "$3"
    check "$1 is accepted" "$(is "$status" 0)"
    check "$1 adds a version" "$([[ "$calls" == *"secrets versions add $2 --project=test-project"* ]] && echo true || echo false)"
    if [ -f "$STUB_WRITTEN" ]; then
        check "$1 writes the canonical form" "$(is "$(cat "$STUB_WRITTEN")" "$(jq -cjS . "$WORK/principals.json")")"
        keep accept "$2" "$STUB_WRITTEN"
    else
        check "$1 writes a file" false
    fi
}

# refuses <label> <secret> <json> <message>: exits 1 naming <message>, makes
# no gcloud call, and prints no address from the file.
refuses() {
    run test-project "$2" "$3"
    check "$1 is refused" "$(is "$status" 1)"
    check "$1 names the problem" "$(says "$4")"
    check "$1 makes no gcloud call" "$(is "$calls" "")"
    check "$1 prints no address" "$([[ "$out" != *example.org* ]] && echo true || echo false)"
    # The module sees what a hand-written version would hold: the raw file
    # when the script refused it for its JSON shape, else its canonical form,
    # so each schema rule is tested on its own.
    case "$4" in "has no schema") return ;; esac
    case "$4" in
    "repeats a key" | "exactly one JSON object" | "is not valid JSON") keep refuse "$2" "$WORK/principals.json" ;;
    *)
        jq -cjS . "$WORK/principals.json" >"$WORK/canonical.json"
        keep refuse "$2" "$WORK/canonical.json"
        ;;
    esac
}

F=dfo-test-foundation-principals
A=dfo-test-ai-principals
T=dfo-test-telemetry-principals
G='"group:a@example.org"'
G2='"group:b@example.org"'
FE='"ingestion_operators": {}, "budget_alerts": {}'

accepts "foundation" "$F" "{\"applier_impersonators\": {\"appliers\": $G}, $FE}"
accepts "foundation with budget alerts and a domain member" "$F" '{"applier_impersonators": {}, "ingestion_operators": {"org": "domain:example.org"}, "budget_alerts": {"finance": "a@example.org"}}'
accepts "foundation, unordered and spaced" "$F" $'{ "budget_alerts" : {},\n  "ingestion_operators": {"b": "user:b@example.org", "a": "serviceAccount:x@p.iam.gserviceaccount.com"},\n  "applier_impersonators": {} }\n'
refuses "foundation missing key" "$F" '{"applier_impersonators": {}}' "missing top-level key ingestion_operators"
refuses "foundation missing budget_alerts" "$F" '{"applier_impersonators": {}, "ingestion_operators": {}}' "missing top-level key budget_alerts"
refuses "foundation extra key" "$F" "{\"applier_impersonators\": {}, $FE, \"readers\": {}}" "unexpected top-level key readers"
refuses "foundation bare address" "$F" "{\"applier_impersonators\": {\"x\": \"a@example.org\"}, $FE}" "each applier_impersonators value must be"
refuses "foundation domain member with an address" "$F" "{\"applier_impersonators\": {\"x\": \"domain:a@example.org\"}, $FE}" "each applier_impersonators value must be"
refuses "foundation duplicate member" "$F" "{\"applier_impersonators\": {}, \"ingestion_operators\": {\"x\": $G, \"y\": $G}, \"budget_alerts\": {}}" "ingestion_operators holds the same value under two labels"
refuses "foundation address as label" "$F" "{\"applier_impersonators\": {\"a@example.org\": $G}, $FE}" "applier_impersonators has a label outside"
refuses "foundation label ending in a newline" "$F" "{\"applier_impersonators\": {\"a\\n\": $G}, $FE}" "applier_impersonators has a label outside"
refuses "foundation non-object member list" "$F" "{\"applier_impersonators\": [$G], $FE}" "applier_impersonators must be an object"
refuses "foundation prefixed budget alert" "$F" "{\"applier_impersonators\": {}, \"ingestion_operators\": {}, \"budget_alerts\": {\"x\": $G}}" "each budget_alerts value must be a bare email address"
refuses "foundation duplicate budget alert" "$F" '{"applier_impersonators": {}, "ingestion_operators": {}, "budget_alerts": {"x": "a@example.org", "y": "a@example.org"}}' "budget_alerts holds the same value"
refuses "foundation repeated top-level key" "$F" "{\"applier_impersonators\": {\"x\": $G}, \"applier_impersonators\": {}, $FE}" "repeats a key"
refuses "foundation repeated inner key" "$F" "{\"applier_impersonators\": {\"x\": $G, \"x\": $G2}, $FE}" "repeats a key"
refuses "telemetry file to foundation" "$F" "{\"readers\": {\"x\": $G}, \"alerts\": {\"x\": \"a@example.org\"}}" "missing top-level key applier_impersonators"

accepts "ai" "$A" "{\"studio_token_readers\": {\"testers\": $G}, \"mcp_token_readers\": {}}"
accepts "ai with both empty" "$A" '{"studio_token_readers": {}, "mcp_token_readers": {}}'
refuses "ai missing key" "$A" "{\"studio_token_readers\": {\"testers\": $G}}" "missing top-level key mcp_token_readers"
refuses "ai unknown prefix" "$A" '{"studio_token_readers": {"x": "team:a@example.org"}, "mcp_token_readers": {}}' "each studio_token_readers value must be"
refuses "ai non-string member" "$A" '{"studio_token_readers": {"x": 1}, "mcp_token_readers": {}}' "each studio_token_readers value must be"
refuses "ai duplicate member" "$A" "{\"studio_token_readers\": {}, \"mcp_token_readers\": {\"x\": $G, \"y\": $G}}" "mcp_token_readers holds the same value"
refuses "ai upper-case address" "$A" '{"studio_token_readers": {"x": "group:A@example.org"}, "mcp_token_readers": {}}' "each studio_token_readers value must be"
refuses "ai case-only duplicate" "$A" '{"studio_token_readers": {"x": "group:a@example.org", "y": "group:A@example.org"}, "mcp_token_readers": {}}' "each studio_token_readers value must be"
refuses "ai no-break space in an address" "$A" '{"studio_token_readers": {"x": "group:a b@example.org"}, "mcp_token_readers": {}}' "each studio_token_readers value must be"
refuses "ai non-ASCII address" "$A" '{"studio_token_readers": {"x": "group:é@example.org"}, "mcp_token_readers": {}}' "each studio_token_readers value must be"

accepts "telemetry" "$T" "{\"readers\": {\"x\": $G, \"y\": $G2}, \"alerts\": {\"x\": \"a@example.org\"}}"
refuses "telemetry missing readers" "$T" '{"alerts": {"x": "a@example.org"}}' "missing top-level key readers"
refuses "telemetry empty alerts" "$T" "{\"readers\": {\"x\": $G}, \"alerts\": {}}" "alerts must hold at least 1 entry"
refuses "telemetry prefixed alert" "$T" "{\"readers\": {}, \"alerts\": {\"x\": $G}}" "each alerts value must be a bare email address"
refuses "telemetry reader with no prefix" "$T" '{"readers": {"x": "a@example.org"}, "alerts": {"x": "b@example.org"}}' "each readers value must be"
refuses "telemetry duplicate alert" "$T" '{"readers": {}, "alerts": {"x": "a@example.org", "y": "a@example.org"}}' "alerts holds the same value"
refuses "telemetry alert with a trailing space" "$T" '{"readers": {}, "alerts": {"x": "a@example.org "}}' "each alerts value must be a bare email address"

refuses "concatenated objects" "$F" "{\"applier_impersonators\": {}, $FE}{\"applier_impersonators\": {}, $FE}" "exactly one JSON object"
refuses "empty file" "$F" '' "exactly one JSON object"
refuses "whitespace-only file" "$F" $' \n' "exactly one JSON object"
refuses "top-level array" "$F" '[]' "exactly one JSON object"
refuses "invalid JSON" "$F" '{"applier_impersonators": ' "is not valid JSON"
refuses "unknown stack" dfo-test-website-principals '{}' "has no schema"
refuses "secret name with no stack" dfo-principals '{}' "has no schema"

run Bad_Project "$F" "{\"applier_impersonators\": {}, $FE}"
check "bad project id is refused" "$(is "$status" 1)"
check "bad project id names the problem" "$(says 'is not a GCP project id')"
check "bad project id makes no gcloud call" "$(is "$calls" "")"

# Parity: one terraform test run per kept case, against the module's own
# postconditions, with the stack the case's secret name names, so both sides
# read the stack's schema from the module's schemas.json.
if command -v terraform >/dev/null; then
    [ "$parity_cases" -gt 0 ] || { echo "FAIL no parity cases kept"; exit 1; }
    for stack in $(jq -r '.stacks | keys[]' "$SCRIPT_DIR/../infra/modules/principals-secret/schemas.json"); do
        check "parity covers an accepted $stack case" "$(grep -qx "accept dfo-test-$stack-principals" "$WORK"/parity/*.case && echo true || echo false)"
    done
    mod="$WORK/module"
    cp -R "$SCRIPT_DIR/../infra/modules/principals-secret" "$mod"
    mkdir -p "$mod/tests"
    tests="$mod/tests/parity.tftest.hcl"
    printf 'mock_provider "google" {}\n\nvariables {\n  project_id = "test-project"\n  namespace  = "dfo-test"\n}\n' >"$tests"
    for i in $(seq 1 "$parity_cases"); do
        read -r verdict secret <"$WORK/parity/$i.case"
        stack=${secret#dfo-test-}
        stack=${stack%-principals}
        {
            printf '\nrun "case_%s_%s" {\n  command = plan\n  variables {\n    stack = "%s"\n  }\n' "$i" "$verdict" "$stack"
            printf '  override_data {\n    target = data.google_secret_manager_secret_version.this\n    values = { secret_data = %s }\n  }\n' "$(jq -Rs . "$WORK/parity/$i.json")"
            [ "$verdict" = refuse ] && printf '  expect_failures = [data.google_secret_manager_secret_version.this]\n'
            printf '}\n'
        } >>"$tests"
    done
    if parity=$(cd "$mod" && terraform init -backend=false -input=false -no-color >/dev/null && terraform test -no-color 2>&1); then
        passed=$(grep -c '^  run ".*\.\.\. pass$' <<<"$parity" || true)
        out=$parity calls=""
        check "module agrees with the script on all $parity_cases parity cases" "$(is "$passed" "$parity_cases")"
    else
        out=$(grep -E '\.\.\. fail|Error' <<<"$parity" || true) calls=""
        check "module agrees with the script on all $parity_cases parity cases" false
    fi
else
    echo "skip parity: terraform not on PATH"
fi

[ "$cases" -gt 0 ] || { echo "no cases ran"; exit 1; }
if [ "$failures" -eq 0 ]; then
    echo "All $cases checks passed."
    exit 0
else
    echo "$failures of $cases check(s) failed."
    exit 1
fi
