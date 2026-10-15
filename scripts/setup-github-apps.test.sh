#!/usr/bin/env bash
# End-to-end tests for setup-github-apps.sh against a stub `gh`, so nothing
# reaches GitHub. The stub logs every call and answers environment reads as
# setup-github-repos.sh leaves them. Not wired into CI or pre-commit. Run by
# hand after touching the script, github-environment.sh or
# deploy-targets.sh:
#   scripts/setup-github-apps.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin" "$WORK/keys"

REPO="$WORK/repo"
mkdir -p "$REPO/scripts"
cp "$SCRIPT_DIR"/deploy-targets.sh "$SCRIPT_DIR"/github-environment.sh "$SCRIPT_DIR"/setup-github-apps.sh "$REPO/scripts/"
export STUB_LOG="$WORK/calls.log"

# Fake keys whose bodies are unique strings, so a leak shows up in a grep.
for app in pin docsync release; do
    printf '%s\n' "-----BEGIN RSA PRIVATE KEY-----" "$(echo "$app" | tr '[:lower:]' '[:upper:]')SECRETBODY" "-----END RSA PRIVATE KEY-----" >"$WORK/keys/$app.pem"
done
printf '%s\n' "not a key" >"$WORK/keys/bad.pem"

# gh: logs its arguments. A `secret set` also logs the stdin it was fed, as
# `stdin=<second line>`, so a case can check which key reached which
# secret. An environment GET answers with custom branch policies, and a
# policy listing with `main` for production and `dev` otherwise, as
# setup-github-repos.sh leaves them. The environment path in
# $STUB_MISSING_ENV answers 404.
cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1 $2" = "secret set" ]; then
    echo "gh $* stdin=$(sed -n 2p)" >>"$STUB_LOG"
else
    echo "gh $*" >>"$STUB_LOG"
fi
[ "$1" = api ] || exit 0
case "$*" in *--method*) exit 0 ;; esac
path=""
for a in "$@"; do case "$a" in repos/*) path="$a" ;; esac; done
env_path="${path%/deployment-branch-policies}"
if [ "$env_path" = "${STUB_MISSING_ENV:-}" ]; then
    echo "gh: Not Found (HTTP 404)" >&2
    exit 1
fi
case "$path" in
*/production/deployment-branch-policies) printf 'main\tbranch\n' ;;
*/deployment-branch-policies) printf 'dev\tbranch\n' ;;
*/environments/*) echo '{"protection_rules":[{"type":"branch_policy"}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
[ "$(command -v gh)" = "$WORK/bin/gh" ] || { echo "gh stub not first on PATH" >&2; exit 1; }

failures=0

# run <args...>: runs the script with a fresh log, stdin closed, leaving
# $status, $out and $calls.
run() {
    : >"$STUB_LOG"
    set +e
    out="$("$REPO/scripts/setup-github-apps.sh" "$@" 2>&1 </dev/null)"
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
says() { [[ "$out" == *"$1"* ]] && echo true || echo false; }
has() { [[ "$calls" == *"$1"* ]] && echo true || echo false; }
lacks() { [[ "$calls" != *"$1"* ]] && echo true || echo false; }
count() { grep -cE "$1" "$STUB_LOG" || true; }
no_key_in_output() { [[ "$out" != *SECRETBODY* ]] && echo true || echo false; }

pin_args=(--pin-key "$WORK/keys/pin.pem" --pin-client-id Iv23liPin)
docsync_args=(--docsync-key "$WORK/keys/docsync.pem" --docsync-client-id Iv23liDocsync)
release_args=(--release-key "$WORK/keys/release.pem" --release-client-id Iv23liRelease)

# 1. All three Apps: each pair lands in its one environment, and nowhere
# else.
run "${pin_args[@]}" "${docsync_args[@]}" "${release_args[@]}"
check "all exits 0" "$(is "$status" 0)"
covered=0
while read -r prefix repo env id key; do
    check "sets $prefix variable in $repo $env" "$(has "gh variable set ${prefix}_CLIENT_ID --env $env --repo DevelopmentFinanceObservatory/$repo --body $id")"
    check "sends the $prefix key to $repo $env" "$(has "gh secret set ${prefix}_PRIVATE_KEY --env $env --repo DevelopmentFinanceObservatory/$repo stdin=$key")"
    check "checks $repo $env before writing" "$(has "gh api repos/DevelopmentFinanceObservatory/$repo/environments/$env")"
    covered=$((covered + 1))
done <<<"PIN_APP dcp dev Iv23liPin PINSECRETBODY
DOCSYNC_APP docs docsync Iv23liDocsync DOCSYNCSECRETBODY
RELEASE_APP dcp production Iv23liRelease RELEASESECRETBODY"
check "covered 3 Apps (covered $covered)" "$(is "$covered" 3)"
check "writes exactly 6 values" "$(is "$(count '^gh (variable|secret) set ')" 6)"
check "writes nothing at repo level" "$(is "$(grep -E '^gh (variable|secret) set ' "$STUB_LOG" | grep -vc ' --env ' || true)" 0)"
check "changes no environment" "$(lacks '--method')"
check "sets no reader value" "$(lacks READER_APP)"
check "touches no ONEcampaign repo" "$(lacks ONEcampaign)"
check "prints no key" "$(no_key_in_output)"

# 2. One App alone, as for a key rotation.
run "${release_args[@]}"
check "release alone exits 0" "$(is "$status" 0)"
check "release alone writes 2 values" "$(is "$(count '^gh (variable|secret) set ')" 2)"
check "release alone leaves pin alone" "$(lacks PIN_APP)"

# 3. --dry-run reads but writes nothing, naming the key file in place of
# its contents.
run --dry-run "${pin_args[@]}"
check "dry run exits 0" "$(is "$status" 0)"
check "dry run makes no write" "$(is "$(count '^gh (variable set|secret set)')" 0)"
check "dry run prints the key file" "$(says "DRY-RUN: gh secret set PIN_APP_PRIVATE_KEY --env dev --repo DevelopmentFinanceObservatory/dcp < $WORK/keys/pin.pem")"
check "dry run prints no key" "$(no_key_in_output)"

# 4. A missing environment stops a real run before any write; a dry run
# reports it and goes on.
export STUB_MISSING_ENV=repos/DevelopmentFinanceObservatory/docs/environments/docsync
run "${pin_args[@]}" "${docsync_args[@]}"
check "missing environment exits 1" "$(is "$status" 1)"
check "missing environment is named" "$(says 'DevelopmentFinanceObservatory/docs (docsync): environment does not exist')"
check "missing environment writes nothing, pin included" "$(lacks ' set ')"
check "missing environment creates nothing" "$(lacks '--method')"
run --dry-run "${docsync_args[@]}"
check "dry run with a missing environment exits 0" "$(is "$status" 0)"
check "dry run with a missing environment says a real run stops" "$(says 'a real run stops here')"
unset STUB_MISSING_ENV

# 5. Bad or missing input fails before any gh call.
expect_refused() {
    local label="$1" fragment="$2"
    shift 2
    run "$@"
    check "$label exits 1" "$(is "$status" 1)"
    check "$label says '$fragment'" "$(says "$fragment")"
    check "$label makes no gh call" "$(is "$calls" "")"
}
expect_refused "no App" "give at least one App's key and client ID"
expect_refused "half a pair" "give both --pin-key and --pin-client-id" --pin-key "$WORK/keys/pin.pem"
expect_refused "reader App" "Unrecognized argument: --reader-key" --reader-key "$WORK/keys/pin.pem"
expect_refused "an environment argument" "Unrecognized argument: dfo-prod" dfo-prod "${pin_args[@]}"
expect_refused "unreadable key" "is not a readable file" --pin-key "$WORK/keys/none.pem" --pin-client-id Iv23liPin
expect_refused "non-PEM key" "does not start with a PEM private key header" --pin-key "$WORK/keys/bad.pem" --pin-client-id Iv23liPin
expect_refused "numeric App ID" "is not a GitHub App client ID" --pin-key "$WORK/keys/pin.pem" --pin-client-id 123456
expect_refused "option without a value" "--docsync-key needs a value" --docsync-key

run --help
check "--help exits 0 and prints usage" "$([ "$status" -eq 0 ] && [[ "$out" == *"Usage: scripts/setup-github-apps.sh"* ]] && echo true || echo false)"

if [ "$failures" -eq 0 ]; then
    echo "All scenarios passed."
    exit 0
else
    echo "$failures scenario(s) failed."
    exit 1
fi
