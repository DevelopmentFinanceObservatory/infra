#!/usr/bin/env bash
# Tests for bootstrap-principals.sh against a stub `gcloud`, so nothing
# reaches GCP. The stub logs every call; the cases check that each secret
# name suffix accepts its own schema, refuses every malformed file before any
# gcloud call, and never echoes a value from the file. The `edit` cases run
# the script with EDITOR set to a script that edits the file it is given.
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
export STUB_LOG="$WORK/calls.log" STUB_WRITTEN="$WORK/written.json" STUB_CREATED="$WORK/created" STUB_CONTENT="$WORK/stored.json"

# gcloud: logs its arguments and copies the file `versions add` sends.
# `secrets versions list` accepts exactly the arguments the script is meant
# to send (filter, sort-by, limit, format) and fails on any other list. It
# fails with NOT_FOUND unless $STUB_EXISTS is set or `secrets create` ran,
# with PERMISSION_DENIED when $STUB_LIST_FAIL is set, and otherwise prints
# $STUB_LATEST, the latest enabled version number (empty for none), on the
# first list call and $STUB_RECHECK (default $STUB_LATEST) on later ones.
# `secrets versions access N` prints the file $STUB_CONTENT when N is
# $STUB_LATEST and fails otherwise. Every other call succeeds.
cat >"$WORK/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "gcloud $*" >>"$STUB_LOG"
case "$1 $2 $3" in
"secrets versions list")
    [ "$*" = "secrets versions list $4 --project=test-project --filter=state:ENABLED --sort-by=~createTime --limit=1 --format=value(name.basename())" ] ||
        { echo "stub: unexpected versions list arguments" >&2; exit 2; }
    [ -n "${STUB_EXISTS:-}" ] || [ -e "$STUB_CREATED" ] ||
        { echo "ERROR: (gcloud.secrets.versions.list) NOT_FOUND: Secret [projects/1/secrets/$4] not found." >&2; exit 1; }
    [ -z "${STUB_LIST_FAIL:-}" ] ||
        { echo "ERROR: (gcloud.secrets.versions.list) PERMISSION_DENIED: caller lacks access" >&2; exit 1; }
    if [ "$(grep -c 'secrets versions list' "$STUB_LOG")" -eq 1 ]; then
        echo "${STUB_LATEST-}"
    else
        echo "${STUB_RECHECK-${STUB_LATEST-}}"
    fi
    ;;
"secrets versions access")
    [ "$4" = "${STUB_LATEST-}" ] && [ -z "${STUB_ACCESS_FAIL:-}" ] ||
        { echo "ERROR: (gcloud.secrets.versions.access) cannot read version $4" >&2; exit 1; }
    cat "$STUB_CONTENT"
    ;;
"secrets create "*) touch "$STUB_CREATED" ;;
esac
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
    rm -f "$STUB_WRITTEN" "$STUB_CREATED"
    printf '%s' "$3" >"$WORK/principals.json"
    status=0
    out=$("$SCRIPT_DIR/bootstrap-principals.sh" "$1" "$2" "$WORK/principals.json" 2>&1) || status=$?
    calls=$(cat "$STUB_LOG")
}

# run_edit <project> <secret>: runs `edit`, setting the same variables.
run_edit() {
    : >"$STUB_LOG"
    rm -f "$STUB_WRITTEN" "$STUB_CREATED" "$EDITOR_PATH"
    status=0
    out=$("$SCRIPT_DIR/bootstrap-principals.sh" edit "$1" "$2" 2>&1) || status=$?
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
V=dfo-test-apis-principals
T=dfo-test-telemetry-principals
G='"group:a@example.org"'
G2='"group:b@example.org"'
FE='"ingestion_operators": {}, "budget_alerts": {}'

accepts "foundation" "$F" "{\"applier_impersonators\": {\"appliers\": $G}, $FE}"
accepts "foundation with budget alerts" "$F" '{"applier_impersonators": {}, "ingestion_operators": {"ops": "group:ops@example.org"}, "budget_alerts": {"finance": "a@example.org"}}'
accepts "foundation, unordered and spaced" "$F" $'{ "budget_alerts" : {},\n  "ingestion_operators": {"b": "user:b@example.org", "a": "group:a@example.org"},\n  "applier_impersonators": {} }\n'
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
refuses "ai bool member" "$A" '{"studio_token_readers": {"x": true}, "mcp_token_readers": {}}' "each studio_token_readers value must be"
refuses "ai null member" "$A" '{"studio_token_readers": {"x": null}, "mcp_token_readers": {}}' "each studio_token_readers value must be"
accepts "ai member with a 4-character address" "$A" '{"studio_token_readers": {"x": "group:a@bc", "y": "user:a@bc"}, "mcp_token_readers": {}}'
refuses "ai member with a 3-character address" "$A" '{"studio_token_readers": {"x": "group:a@b"}, "mcp_token_readers": {}}' "at least 4 characters"
refuses "ai duplicate member" "$A" "{\"studio_token_readers\": {}, \"mcp_token_readers\": {\"x\": $G, \"y\": $G}}" "mcp_token_readers holds the same value"
refuses "ai upper-case address" "$A" '{"studio_token_readers": {"x": "group:A@example.org"}, "mcp_token_readers": {}}' "each studio_token_readers value must be"
refuses "ai case-only duplicate" "$A" '{"studio_token_readers": {"x": "group:a@example.org", "y": "group:A@example.org"}, "mcp_token_readers": {}}' "each studio_token_readers value must be"
refuses "ai no-break space in an address" "$A" '{"studio_token_readers": {"x": "group:a b@example.org"}, "mcp_token_readers": {}}' "each studio_token_readers value must be"
refuses "ai non-ASCII address" "$A" '{"studio_token_readers": {"x": "group:é@example.org"}, "mcp_token_readers": {}}' "each studio_token_readers value must be"

accepts "apis" "$V" "{\"invokers\": {\"dev-1\": \"user:dev1@example.org\", \"devs\": $G}}"
accepts "apis with an empty object" "$V" '{"invokers": {}}'
refuses "apis missing key" "$V" '{}' "missing top-level key invokers"
refuses "apis ai file" "$V" '{"studio_token_readers": {}, "mcp_token_readers": {}}' "missing top-level key invokers"
refuses "apis bare address" "$V" '{"invokers": {"x": "a@example.org"}}' "each invokers value must be"
refuses "apis duplicate member" "$V" "{\"invokers\": {\"x\": $G, \"y\": $G}}" "invokers holds the same value"
accepts "telemetry" "$T" "{\"readers\": {\"x\": $G, \"y\": $G2}, \"alerts\": {\"x\": \"a@example.org\"}}"
refuses "telemetry missing readers" "$T" '{"alerts": {"x": "a@example.org"}}' "missing top-level key readers"
refuses "telemetry empty alerts" "$T" "{\"readers\": {\"x\": $G}, \"alerts\": {}}" "alerts must hold at least 1 entry"
refuses "telemetry prefixed alert" "$T" "{\"readers\": {}, \"alerts\": {\"x\": $G}}" "each alerts value must be a bare email address"
refuses "telemetry reader with no prefix" "$T" '{"readers": {"x": "a@example.org"}, "alerts": {"x": "b@example.org"}}' "each readers value must be"
accepts "telemetry 4-character alert" "$T" '{"readers": {}, "alerts": {"x": "a@bc"}}'
refuses "telemetry 3-character alert" "$T" '{"readers": {}, "alerts": {"x": "a@b"}}' "at least 4 characters"
refuses "telemetry number alert" "$T" '{"readers": {}, "alerts": {"x": 1234}}' "each alerts value must be"
refuses "telemetry duplicate alert" "$T" '{"readers": {}, "alerts": {"x": "a@example.org", "y": "a@example.org"}}' "alerts holds the same value"
refuses "telemetry alert with a trailing space" "$T" '{"readers": {}, "alerts": {"x": "a@example.org "}}' "each alerts value must be a bare email address"

# Every object that takes person values refuses each machine member type, so
# loosening any of them fails a row here. <base> holds the stack's other keys.
machine_members=(
    'serviceAccount:x@p.iam.gserviceaccount.com'
    'domain:example.org'
    'principalSet://iam.googleapis.com/projects/1/locations/global/workloadIdentityPools/p/*'
)
refuses_machine_members() {
    local secret=$1 object=$2 base=$3 member
    for member in "${machine_members[@]}"; do
        refuses "$secret $object with a ${member%%:*} member" "$secret" \
            "$(jq -c --arg k "$object" --arg m "$member" '.[$k] = {x: $m}' <<<"$base")" \
            "each $object value must be group: or user:"
    done
}
refuses_machine_members "$F" applier_impersonators "{\"ingestion_operators\": {}, \"budget_alerts\": {}}"
refuses_machine_members "$F" ingestion_operators '{"applier_impersonators": {}, "budget_alerts": {}}'
refuses_machine_members "$A" studio_token_readers '{"mcp_token_readers": {}}'
refuses_machine_members "$A" mcp_token_readers '{"studio_token_readers": {}}'
refuses_machine_members "$V" invokers '{}'
refuses_machine_members "$T" readers '{"alerts": {"x": "a@example.org"}}'

# has <label> <pattern>: the logged calls contain <pattern>.
has() { check "$1" "$([[ "$calls" == *"$2"* ]] && echo true || echo false)"; }
lacks() { check "$1" "$([[ "$calls" != *"$2"* ]] && echo true || echo false)"; }
# line_of <pattern>: the number of the first logged call containing <pattern>.
line_of() { grep -n -m1 -F -- "$1" "$STUB_LOG" | cut -d: -f1; }
# writes_nothing <label>: no secret was created, granted or given a version.
writes_nothing() {
    check "$1 writes nothing" "$([[ "$calls" != *"versions add"* && "$calls" != *"secrets create"* && "$calls" != *"add-iam-policy-binding"* ]] && echo true || echo false)"
}

# The stub refuses a versions list call that drops or changes an argument, so
# the script's call is pinned to the filter, sort order, limit and format.
for args in \
    "--filter=state:ENABLED --sort-by=~createTime --limit=1" \
    "--sort-by=~createTime --limit=1 --format=value(name.basename())" \
    "--filter=state:ENABLED --limit=1 --format=value(name.basename())" \
    "--filter=state:ENABLED --sort-by=~createTime --format=value(name.basename())" \
    "--filter=state=enabled --sort-by=~createTime --limit=1 --format=value(name.basename())" \
    "--filter=state:ENABLED --sort-by=createTime --limit=1 --format=value(name.basename())"; do
    : >"$STUB_LOG"
    status=0
    # shellcheck disable=SC2086
    out=$(STUB_EXISTS=1 gcloud secrets versions list s --project=test-project $args 2>&1) || status=$?
    calls=""
    check "the stub refuses a versions list call with $args" "$(is "$status" 2)"
done

# Creating a secret: it is created, the planner is granted access, and the
# version is added, in that order, so a rerun after a failed run completes.
accepts "apis secret created" "$V" "{\"invokers\": {\"x\": $G}}"
has "apis secret created is created" "secrets create $V --project=test-project"
check "apis secret created is created before it is granted" "$([ "$(line_of 'secrets create')" -lt "$(line_of 'add-iam-policy-binding')" ] && echo true || echo false)"
check "apis secret created is granted before it gets a version" "$([ "$(line_of 'add-iam-policy-binding')" -lt "$(line_of 'versions add')" ] && echo true || echo false)"

export STUB_EXISTS=1 STUB_LATEST=3
run test-project "$V" "{\"invokers\": {\"x\": $G}}"
check "file form on a secret with a version is refused" "$(is "$status" 1)"
check "file form on a secret with a version names the version" "$(says "already has version 3")"
check "file form on a secret with a version points to edit" "$(says "edit test-project $V")"
writes_nothing "file form on a secret with a version"

STUB_LATEST="" accepts "apis secret left without a version" "$V" "{\"invokers\": {\"x\": $G}}"
lacks "apis secret left without a version is not created again" "secrets create"
has "apis secret left without a version is granted" "add-iam-policy-binding $V"

STUB_LATEST="" STUB_RECHECK=2 run test-project "$V" "{\"invokers\": {\"x\": $G}}"
check "a version added during a first write is refused" "$(is "$status" 1)"
check "a version added during a first write names it" "$(says "now has version 2")"
lacks "a version added during a first write adds none" "versions add"

STUB_LIST_FAIL=1 run test-project "$V" "{\"invokers\": {\"x\": $G}}"
check "a failed list on the file form exits non-zero" "$(is "$status" 1)"
check "a failed list on the file form shows gcloud's error" "$(says "PERMISSION_DENIED")"
writes_nothing "a failed list on the file form"
unset STUB_EXISTS STUB_LATEST

# edit: the script reads the latest enabled version, opens $EDITOR on a copy,
# and writes the edited copy. The editor is a script that records what it was
# given, leaves a swap file beside it, and edits the file with $EDIT_JQ, or
# replaces it with $EDIT_RAW, or exits with $EDIT_EXIT.
export EDITOR_SAW="$WORK/editor-saw.json" EDITOR_PATH="$WORK/editor-path"
cat >"$WORK/editor" <<'EDITOR'
#!/usr/bin/env bash
cp "$1" "$EDITOR_SAW"
echo "$1" >"$EDITOR_PATH"
: >"$1.swp"
[ -z "${EDIT_EXIT:-}" ] || exit "$EDIT_EXIT"
[ -z "${EDIT_RAW+x}" ] || printf '%s' "$EDIT_RAW" >"$1"
[ -z "${EDIT_JQ:-}" ] || { jq "$EDIT_JQ" "$1" >"$1.new" && mv "$1.new" "$1"; }
exit 0
EDITOR
chmod +x "$WORK/editor"
export EDITOR="$WORK/editor"
printf '%s' '{"invokers":{"dev-1":"user:dev1@example.org"}}' >"$STUB_CONTENT"
export STUB_EXISTS=1 STUB_LATEST=3

# editor_dir_gone <label>: the directory holding the editor's file, and the
# swap file beside it, were removed.
editor_dir_gone() {
    check "$1 leaves no temporary file" "$([ -f "$EDITOR_PATH" ] && [ ! -e "$(dirname "$(cat "$EDITOR_PATH")")" ] && echo true || echo false)"
}

EDIT_JQ=".invokers[\"devs\"] = \"group:devs@example.org\"" run_edit test-project "$V"
check "edit is accepted" "$(is "$status" 0)"
check "edit gives the editor the stored version" "$(is "$(jq -cS . "$EDITOR_SAW")" "$(jq -cS . "$STUB_CONTENT")")"
has "edit reads the version it listed" "secrets versions access 3 --secret=$V --project=test-project"
check "edit writes the edited canonical form" "$(is "$(cat "$STUB_WRITTEN" 2>/dev/null)" '{"invokers":{"dev-1":"user:dev1@example.org","devs":"group:devs@example.org"}}')"
check "edit lists the versions before and just before the write" "$(is "$(grep -c 'secrets versions list' "$STUB_LOG")" 2)"
check "edit checks the version immediately before the write" "$(is "$(tail -n 2 "$STUB_LOG" | cut -d' ' -f2-4 | paste -sd, -)" 'secrets versions list,secrets versions add')"
lacks "edit creates nothing" "secrets create"
editor_dir_gone "edit"

run_edit test-project "$V"
check "edit with no change is accepted" "$(is "$status" 0)"
check "edit with no change says so" "$(says "nothing written")"
writes_nothing "edit with no change"
editor_dir_gone "edit with no change"

EDIT_JQ='.invokers.x = "serviceAccount:x@p.iam.gserviceaccount.com"' run_edit test-project "$V"
check "edit adding a service account is refused" "$(is "$status" 1)"
check "edit adding a service account names the problem" "$(says "each invokers value must be group: or user:")"
check "edit adding a service account prints no address" "$([[ "$out" != *example.org* && "$out" != *iam.gserviceaccount.com* ]] && echo true || echo false)"
lacks "edit adding a service account adds no version" "versions add"
editor_dir_gone "edit adding a service account"

EDIT_RAW='' run_edit test-project "$V"
check "edit to an empty file is refused" "$(is "$status" 1)"
check "edit to an empty file names the problem" "$(says "exactly one JSON object")"
lacks "edit to an empty file adds no version" "versions add"

EDIT_EXIT=1 run_edit test-project "$V"
check "edit with a failing editor is refused" "$(is "$status" 1)"
lacks "edit with a failing editor adds no version" "versions add"
editor_dir_gone "edit with a failing editor"

EDIT_JQ='.invokers.x = "group:x@example.org"' STUB_RECHECK=4 run_edit test-project "$V"
check "edit over a newer version is refused" "$(is "$status" 1)"
check "edit over a newer version names both versions" "$(says "latest version of $V is 4, not 3")"
lacks "edit over a newer version adds no version" "versions add"
editor_dir_gone "edit over a newer version"

STUB_ACCESS_FAIL=1 run_edit test-project "$V"
check "edit with a failed read is refused" "$(is "$status" 1)"
check "edit with a failed read does not open the editor" "$([ ! -e "$EDITOR_PATH" ] && echo true || echo false)"
writes_nothing "edit with a failed read"

STUB_LIST_FAIL=1 run_edit test-project "$V"
check "edit with a failed list exits non-zero" "$(is "$status" 1)"
check "edit with a failed list shows gcloud's error" "$(says "PERMISSION_DENIED")"
lacks "edit with a failed list reads no version" "versions access"

STUB_LATEST="" run_edit test-project "$V"
check "edit of a secret with no enabled version is refused" "$(is "$status" 1)"
check "edit of a secret with no enabled version names the problem" "$(says "has no enabled version")"
lacks "edit of a secret with no enabled version reads no version" "versions access"

STUB_EXISTS="" run_edit test-project "$V"
check "edit of a missing secret is refused" "$(is "$status" 1)"
check "edit of a missing secret points to the file form" "$(says "does not exist")"
lacks "edit of a missing secret reads no version" "versions access"
writes_nothing "edit of a missing secret"
unset STUB_EXISTS STUB_LATEST

run_edit test-project dfo-test-website-principals
check "edit of an unknown stack is refused" "$(is "$status" 1)"
check "edit of an unknown stack makes no gcloud call" "$(is "$calls" "")"
run_edit Bad_Project "$V"
check "edit of a bad project id makes no gcloud call" "$(is "$calls" "")"
status=0
out=$("$SCRIPT_DIR/bootstrap-principals.sh" edit test-project 2>&1) || status=$?
check "edit with a missing secret name prints usage" "$(is "$status" 2)"

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
