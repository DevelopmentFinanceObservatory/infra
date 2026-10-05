#!/usr/bin/env bash
# End-to-end tests for setup-github-apps.sh against a stub `gh`, so nothing
# reaches GitHub. The stub logs every call and keeps each environment's
# branch policies in a state directory, so the converge step runs as it
# would against GitHub. Not wired into CI or pre-commit. Run by hand after
# touching the script, github-environment.sh or deploy-targets.sh:
#   scripts/setup-github-apps.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin" "$WORK/keys"

REPO="$WORK/repo"
mkdir -p "$REPO/scripts"
cp "$SCRIPT_DIR"/deploy-targets.sh "$SCRIPT_DIR"/github-environment.sh "$SCRIPT_DIR"/setup-github-apps.sh "$REPO/scripts/"
export STUB_LOG="$WORK/calls.log" STUB_STATE="$WORK/state"

# Fake keys whose bodies are unique strings, so a leak shows up in a grep.
READER_KEY="$WORK/keys/reader.pem"
RELEASE_KEY="$WORK/keys/release.pem"
printf '%s\n' "-----BEGIN RSA PRIVATE KEY-----" "READERSECRETBODY" "-----END RSA PRIVATE KEY-----" >"$READER_KEY"
printf '%s\n' "-----BEGIN PRIVATE KEY-----" "RELEASESECRETBODY" "-----END PRIVATE KEY-----" >"$RELEASE_KEY"
printf '%s\n' "not a key" >"$WORK/keys/bad.pem"

# gh: logs its arguments. A `secret set` also logs the stdin it was fed, as
# `stdin=<first body line>`, so a case can check which key reached which
# secret. An environment GET answers 404 unless $STUB_STATE holds it, or
# answers with a required_reviewers rule for the path in $STUB_FOREIGN. A
# policy POST records the branch; a listing prints what was recorded.
cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1 $2" = "secret set" ]; then
    echo "gh $* stdin=$(sed -n 2p)" >>"$STUB_LOG"
else
    echo "gh $*" >>"$STUB_LOG"
fi
[ "$1" = api ] || exit 0
path=""
for a in "$@"; do case "$a" in repos/*) path="$a" ;; esac; done
key="$STUB_STATE/$(printf '%s' "${path%/deployment-branch-policies*}" | tr '/' '_')"
case "$*" in
*"--method PUT"*) mkdir -p "$STUB_STATE"; touch "$key.env" ;;
*"--method POST"*) mkdir -p "$STUB_STATE"; for a in "$@"; do case "$a" in name=*) echo "${a#name=}" >"$key.branch" ;; esac; done ;;
*"--method"*) ;;
*deployment-branch-policies*'[.id,'*) [ -f "$key.branch" ] && printf '1\t%s\tbranch\n' "$(cat "$key.branch")" ;;
*deployment-branch-policies*) [ -f "$key.branch" ] && printf '%s\tbranch\n' "$(cat "$key.branch")" ;;
*/environments/*)
    if [ "$path" = "${STUB_FOREIGN:-}" ]; then
        echo '{"protection_rules":[{"type":"required_reviewers"}],"deployment_branch_policy":null}'
    elif [ -f "$key.env" ]; then
        echo '{"protection_rules":[{"type":"branch_policy"}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
    else
        echo "gh: Not Found (HTTP 404)" >&2
        exit 1
    fi
    ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
[ "$(command -v gh)" = "$WORK/bin/gh" ] || { echo "gh stub not first on PATH" >&2; exit 1; }

failures=0

# run <args...>: runs the script with fresh state and log, stdin closed so it
# can never prompt, leaving $status, $out and $calls.
run() {
    : >"$STUB_LOG"
    rm -rf "$STUB_STATE"
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

reader_args=(--reader-key "$READER_KEY" --reader-client-id Iv23liReader)
release_args=(--release-key "$RELEASE_KEY" --release-client-id Iv23liRelease)
ten="infra dcp apis ai website pipelines docs ontology spec-kit skills"

# 1. dfo-dev: the reader pair on the five repos that mint it, nothing else.
run dfo-dev "${reader_args[@]}"
check "dev exits 0" "$(is "$status" 0)"
covered=0
for name in ai apis docs pipelines skills; do
    check "dev sets the reader variable on dfo-$name" "$(has "gh variable set READER_APP_CLIENT_ID --repo ONEcampaign/dfo-$name --body Iv23liReader")"
    check "dev sends the reader key to dfo-$name" "$(has "gh secret set READER_APP_PRIVATE_KEY --repo ONEcampaign/dfo-$name stdin=READERSECRETBODY")"
    covered=$((covered + 1))
done
check "dev covered 5 repos (covered $covered)" "$(is "$covered" 5)"
check "dev writes exactly 10 values" "$(is "$(count '^gh (variable|secret) set ')" 10)"
check "dev creates no environment" "$(lacks '--method')"
check "dev writes nothing environment-scoped" "$(lacks ' --env ')"
check "dev sets no release value" "$(lacks RELEASE_APP)"
check "dev touches no new-org repo" "$(lacks DevelopmentFinanceObservatory)"
check "dev prints no key" "$(no_key_in_output)"

# 2. dfo-prod: the reader pair in sync-guard on all ten repos, sync and plan
# on infra, and production on ai and apis; the release pair in sync-guard on
# all ten, sync on infra and production on dcp. Each environment is created
# with a main-only policy. infra's production is created with the same
# policy and holds no value. No repo holds the reader pair at repo level.
run dfo-prod "${reader_args[@]}" "${release_args[@]}"
check "prod exits 0" "$(is "$status" 0)"
covered=0
for name in $ten; do
    slug="DevelopmentFinanceObservatory/$name"
    check "prod sets the reader variable in $name sync-guard" "$(has "gh variable set READER_APP_CLIENT_ID --env sync-guard --repo $slug --body Iv23liReader")"
    check "prod sends the reader key to $name sync-guard" "$(has "gh secret set READER_APP_PRIVATE_KEY --env sync-guard --repo $slug stdin=READERSECRETBODY")"
    check "prod restricts $name sync-guard to main" "$(has "gh api --method POST repos/$slug/environments/sync-guard/deployment-branch-policies -f name=main -f type=branch")"
    check "prod sets the release pair in $name sync-guard" "$(has "gh secret set RELEASE_APP_PRIVATE_KEY --env sync-guard --repo $slug stdin=RELEASESECRETBODY")"
    covered=$((covered + 1))
done
check "prod covered 10 repos (covered $covered)" "$(is "$covered" 10)"
covered=0
while read -r name env; do
    check "prod restricts $name $env to main" "$(has "gh api --method POST repos/DevelopmentFinanceObservatory/$name/environments/$env/deployment-branch-policies -f name=main -f type=branch")"
    check "prod sets the reader variable in $name $env" "$(has "gh variable set READER_APP_CLIENT_ID --env $env --repo DevelopmentFinanceObservatory/$name --body Iv23liReader")"
    check "prod sends the reader key to $name $env" "$(has "gh secret set READER_APP_PRIVATE_KEY --env $env --repo DevelopmentFinanceObservatory/$name stdin=READERSECRETBODY")"
    covered=$((covered + 1))
done <<<"infra sync
infra plan
ai production
apis production"
check "prod covered 4 further reader environments (covered $covered)" "$(is "$covered" 4)"
check "prod writes the reader pair in exactly 14 environments" "$(is "$(count '^gh (variable|secret) set READER_APP_[A-Z_]+ --env ')" 28)"
check "prod writes no repo-level reader value" "$(is "$(count 'READER_APP_[A-Z_]+ --repo')" 0)"
check "prod sends the reader key nowhere but those environments" "$(is "$(count 'stdin=READERSECRETBODY')" 14)"
check "prod puts no reader value in dcp production" "$(lacks "READER_APP_CLIENT_ID --env production --repo DevelopmentFinanceObservatory/dcp")"
while read -r name env; do
    check "prod restricts $name $env to main" "$(has "gh api --method POST repos/DevelopmentFinanceObservatory/$name/environments/$env/deployment-branch-policies -f name=main -f type=branch")"
    check "prod sets the release variable in $name $env" "$(has "gh variable set RELEASE_APP_CLIENT_ID --env $env --repo DevelopmentFinanceObservatory/$name --body Iv23liRelease")"
    check "prod sends the release key to $name $env" "$(has "gh secret set RELEASE_APP_PRIVATE_KEY --env $env --repo DevelopmentFinanceObservatory/$name stdin=RELEASESECRETBODY")"
done <<<"infra sync
dcp production"
check "prod restricts infra production to main" "$(has "gh api --method POST repos/DevelopmentFinanceObservatory/infra/environments/production/deployment-branch-policies -f name=main -f type=branch")"
check "prod writes no value in infra production" "$(lacks "--env production --repo DevelopmentFinanceObservatory/infra")"
check "prod writes no release value in infra plan" "$(lacks "RELEASE_APP_CLIENT_ID --env plan")"
check "prod writes exactly 52 values" "$(is "$(count '^gh (variable|secret) set ')" 52)"
check "prod creates exactly 16 environments" "$(is "$(count '^gh api --method PUT ')" 16)"
check "prod creates each environment once" "$(is "$(grep -E '^gh api --method PUT ' "$STUB_LOG" | sort | uniq -d | wc -l | tr -d ' ')" 0)"
check "prod never sends the release key to a repo-level secret" "$(is "$(count 'RELEASE_APP_PRIVATE_KEY --repo')" 0)"
check "prod touches no ONEcampaign repo" "$(lacks ONEcampaign/)"
check "prod prints no key" "$(no_key_in_output)"

# 3. A rerun against converged environments makes no policy write. The
# state survives because this case skips run's reset.
: >"$STUB_LOG"
set +e
out="$("$REPO/scripts/setup-github-apps.sh" dfo-prod "${reader_args[@]}" "${release_args[@]}" 2>&1 </dev/null)"
status=$?
set -e
calls="$(cat "$STUB_LOG")"
check "prod rerun exits 0" "$(is "$status" 0)"
check "prod rerun makes no policy write" "$(lacks '--method')"

# 4. --dry-run reads but writes nothing, and prints every write it would
# make, naming each key's file in place of its contents.
run dfo-prod --dry-run "${reader_args[@]}" "${release_args[@]}"
check "dry run exits 0" "$(is "$status" 0)"
check "dry run makes no write" "$(is "$(count '^gh (variable set|secret set|api --method)')" 0)"
check "dry run prints 52 value writes" "$(is "$(printf '%s\n' "$out" | grep -cE '^DRY-RUN: gh (variable|secret) set ')" 52)"
check "dry run prints 16 environment creations" "$(is "$(printf '%s\n' "$out" | grep -cE '^DRY-RUN: gh api --method PUT ')" 16)"
check "dry run prints 16 policy creations" "$(is "$(printf '%s\n' "$out" | grep -cE '^DRY-RUN: gh api --method POST ')" 16)"
check "dry run names the reader key file for infra plan" "$(says "secret set READER_APP_PRIVATE_KEY --env plan --repo DevelopmentFinanceObservatory/infra < $READER_KEY")"
check "dry run prints the reader variable in apis production" "$(says "DRY-RUN: gh variable set READER_APP_CLIENT_ID --env production --repo DevelopmentFinanceObservatory/apis --body Iv23liReader")"
check "dry run prints no repo-level reader write" "$(is "$(printf '%s\n' "$out" | grep -cE 'READER_APP_[A-Z_]+ --repo')" 0)"
check "dry run summary counts reader environments" "$(says "set the reader pair in 14 environments")"
check "dry run prints no key" "$(no_key_in_output)"

# 5. An environment carrying another protection rule stops the run before
# any value is written, whether it holds release values or none.
for foreign in dcp/environments/production infra/environments/plan apis/environments/production; do
    export STUB_FOREIGN="repos/DevelopmentFinanceObservatory/$foreign"
    run dfo-prod "${reader_args[@]}" "${release_args[@]}"
    unset STUB_FOREIGN
    check "foreign protection rule on $foreign exits 1" "$(is "$status" 1)"
    check "foreign protection rule on $foreign names the rule" "$(says 'required_reviewers')"
    check "foreign protection rule on $foreign writes no value" "$(lacks ' set ')"
done

# 6. Bad or missing input fails before any gh call.
expect_refused() {
    local label="$1" fragment="$2"
    shift 2
    run "$@"
    check "$label exits 1" "$(is "$status" 1)"
    check "$label says '$fragment'" "$(says "$fragment")"
    check "$label makes no gh call" "$(is "$calls" "")"
}
expect_refused "no environment" "unknown environment ''" "${reader_args[@]}"
expect_refused "unknown environment" "unknown environment 'dfo-staging'" dfo-staging "${reader_args[@]}"
expect_refused "missing reader key off a terminal" "missing --reader-key" dfo-dev --reader-client-id Iv23liReader
expect_refused "missing reader client ID off a terminal" "missing --reader-client-id" dfo-dev --reader-key "$READER_KEY"
expect_refused "missing release key in prod" "missing --release-key" dfo-prod "${reader_args[@]}" --release-client-id Iv23liRelease
expect_refused "release values in dev" "dfo-dev takes no release App credentials" dfo-dev "${reader_args[@]}" "${release_args[@]}"
expect_refused "unreadable key" "is not a readable file" dfo-dev --reader-key "$WORK/keys/none.pem" --reader-client-id Iv23liReader
expect_refused "non-PEM key" "does not start with a PEM private key header" dfo-dev --reader-key "$WORK/keys/bad.pem" --reader-client-id Iv23liReader
expect_refused "numeric App ID" "is not a GitHub App client ID" dfo-dev --reader-key "$READER_KEY" --reader-client-id 123456
expect_refused "option without a value" "--reader-key needs a value" dfo-dev --reader-key
expect_refused "unknown option" "Unrecognized option: --force" dfo-dev --force

run --help
check "--help exits 0 and prints usage" "$([ "$status" -eq 0 ] && [[ "$out" == *"Usage: scripts/setup-github-apps.sh"* ]] && echo true || echo false)"

if [ "$failures" -eq 0 ]; then
    echo "All scenarios passed."
    exit 0
else
    echo "$failures scenario(s) failed."
    exit 1
fi
