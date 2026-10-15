#!/usr/bin/env bash
# End-to-end tests for setup-github-repos.sh against a stub `gh` that keeps
# GitHub's state in files, so --apply's writes land and its read-back reads
# them. Nothing reaches GitHub. It takes about 30 seconds: each case runs
# the script over eleven repos, and every stub call starts jq. Not wired
# into CI or pre-commit. Run by
# hand after touching the script, github-environment.sh or
# deploy-targets.sh:
#   scripts/setup-github-repos.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin"

REPO="$WORK/repo"
mkdir -p "$REPO/scripts"
cp "$SCRIPT_DIR"/deploy-targets.sh "$SCRIPT_DIR"/github-environment.sh "$SCRIPT_DIR"/setup-github-repos.sh "$REPO/scripts/"
export STUB_LOG="$WORK/calls.log" STATE="$WORK/state"
OWNER=DevelopmentFinanceObservatory

# gh: logs its arguments. A GET serves $STATE/<path with / as _>.json, or
# 404s when there is none; --jq runs on it through jq. The writes the
# script makes update that state the way GitHub does: rulesets gain an id
# and source_type, an environment PUT becomes the protection_rules a GET
# returns, and the environments and branch-policy listings follow.
cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >>"$STUB_LOG"
[ "$1 $2" = "auth status" ] && exit 0
[ "$1" = api ] || exit 0
shift
method=GET path="" input="" jqf="" silent=false fields=()
while [ "$#" -gt 0 ]; do
    case "$1" in
    --method) method="$2"; shift ;;
    --input) input="$2"; shift ;;
    --jq) jqf="$2"; shift ;;
    -H) shift ;;
    -f) fields+=("$2"); shift ;;
    --silent) silent=true ;;
    --paginate) ;;
    *) path="${1%%\?*}" ;;
    esac
    shift
done
if [ "$method" != GET ] && [ "$path" = "${STUB_DROP:-}" ]; then exit 0; fi
f() { printf '%s/%s.json' "$STATE" "$(printf '%s' "$1" | tr '/' '_')"; }
field() { local x; for x in "${fields[@]}"; do case "$x" in "$1="*) printf '%s' "${x#*=}" ;; esac; done; }
# A repo's environments listing, rebuilt from its environment files.
relist_envs() {
    local repo_path="$1" files
    files="$(ls "$STATE"/"$(printf '%s' "$repo_path/environments/" | tr '/' '_')"*.json 2>/dev/null | grep -v deployment-branch-policies || true)"
    if [ -z "$files" ]; then
        echo '{"environments":[]}' >"$(f "$repo_path/environments")"
    else
        # shellcheck disable=SC2086
        jq -s '{environments: .}' $files >"$(f "$repo_path/environments")"
    fi
}
case "$method" in
GET)
    [ -f "$(f "$path")" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    if [ "$silent" = true ]; then :; elif [ -n "$jqf" ]; then jq -r "$jqf" "$(f "$path")"; else cat "$(f "$path")"; fi
    ;;
POST)
    case "$path" in
    */rulesets)
        id=$(( $(cat "$STATE/next_id") + 1 )); echo "$id" >"$STATE/next_id"
        jq --argjson id "$id" '. + {id: $id, source_type: "Repository"}' "$input" >"$(f "$path/$id")"
        jq --argjson id "$id" --arg name "$(jq -r .name "$input")" '. + [{id: $id, name: $name, source_type: "Repository"}]' "$(f "$path")" >"$STATE/tmp" && mv "$STATE/tmp" "$(f "$path")"
        ;;
    */deployment-branch-policies)
        id=$(( $(cat "$STATE/next_id") + 1 )); echo "$id" >"$STATE/next_id"
        [ -f "$(f "$path")" ] || echo '{"branch_policies":[]}' >"$(f "$path")"
        jq --argjson id "$id" --arg n "$(field name)" --arg t "$(field type)" '.branch_policies += [{id: $id, name: $n, type: $t}]' "$(f "$path")" >"$STATE/tmp" && mv "$STATE/tmp" "$(f "$path")"
        ;;
    esac
    ;;
PUT)
    case "$path" in
    */rulesets/*) jq --argjson id "${path##*/}" '. + {id: $id, source_type: "Repository"}' "$input" >"$(f "$path")" ;;
    */environments/*)
        jq --arg name "${path##*/}" '{
            name: $name,
            protection_rules: (
                (if (.reviewers // []) == [] then [] else [{type: "required_reviewers", prevent_self_review: .prevent_self_review,
                    reviewers: [.reviewers[] | {type, reviewer: {id}}]}] end)
                + (if (.wait_timer // 0) > 0 then [{type: "wait_timer", wait_timer: .wait_timer}] else [] end)
                + (if .deployment_branch_policy == null then [] else [{type: "branch_policy"}] end)),
            deployment_branch_policy: .deployment_branch_policy
        }' "$input" >"$(f "$path")"
        if jq -e '.deployment_branch_policy == null' "$input" >/dev/null; then rm -f "$(f "$path/deployment-branch-policies")"
        elif [ ! -f "$(f "$path/deployment-branch-policies")" ]; then echo '{"branch_policies":[]}' >"$(f "$path/deployment-branch-policies")"; fi
        relist_envs "${path%/environments/*}"
        ;;
    */teams/*/repos/*) echo '{"permissions":{"push":true}}' >"$(f "$path")" ;;
    esac
    ;;
PATCH)
    jq --arg b "$(field default_branch)" '.default_branch = $b' "$(f "$path")" >"$STATE/tmp" && mv "$STATE/tmp" "$(f "$path")"
    ;;
DELETE)
    case "$path" in
    */deployment-branch-policies/*)
        p="${path%/*}"
        jq --argjson id "${path##*/}" '.branch_policies |= map(select(.id != $id))' "$(f "$p")" >"$STATE/tmp" && mv "$STATE/tmp" "$(f "$p")"
        ;;
    */environments/*)
        rm -f "$(f "$path")" "$(f "$path/deployment-branch-policies")" "$(f "$path/variables")"
        relist_envs "${path%/environments/*}"
        ;;
    */actions/variables/*)
        p="${path%/*}"
        jq --arg n "${path##*/}" '.variables |= map(select(.name != $n))' "$(f "$p")" >"$STATE/tmp" && mv "$STATE/tmp" "$(f "$p")"
        ;;
    esac
    ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
[ "$(command -v gh)" = "$WORK/bin/gh" ] || { echo "gh stub not first on PATH" >&2; exit 1; }

all="infra dcp apis ai website pipelines docs ontology spec-kit skills site-qa"

# put <path> <json>: writes one stub state file.
put() { printf '%s\n' "$2" >"$STATE/$(printf '%s' "$1" | tr '/' '_').json"; }

# seed: the org as it stands before cutover. Every repo defaults to main
# and has a `dev` branch, release holds write, and a `main` ruleset targets
# ~DEFAULT_BRANCH. Every repo has sync-guard; infra also sync, plan and
# production, the service repos production, all admitting main without
# reviewers. infra holds its WIF values at repo level.
seed() {
    local name slug id=100 env envs
    rm -rf "$STATE"
    mkdir -p "$STATE"
    put users/jm-rivera '{"id":7374450}'
    put "orgs/$OWNER/teams/release" '{"id":19851660}'
    for name in $all; do
        slug="$OWNER/$name"
        id=$((id + 1))
        put "repos/$slug" '{"default_branch":"main"}'
        put "repos/$slug/branches/dev" '{"name":"dev"}'
        put "orgs/$OWNER/teams/release/repos/$slug" '{"permissions":{"push":true}}'
        put "repos/$slug/rulesets" "[{\"id\":$id,\"name\":\"main\",\"source_type\":\"Repository\"}]"
        put "repos/$slug/rulesets/$id" "{\"id\":$id,\"name\":\"main\",\"target\":\"branch\",\"enforcement\":\"active\",\"source_type\":\"Repository\",\"bypass_actors\":[],\"conditions\":{\"ref_name\":{\"include\":[\"~DEFAULT_BRANCH\"],\"exclude\":[]}},\"rules\":[{\"type\":\"deletion\"},{\"type\":\"non_fast_forward\"},{\"type\":\"required_status_checks\",\"parameters\":{\"strict_required_status_checks_policy\":true,\"required_status_checks\":[{\"context\":\"sync-guard\"}]}}]}"
        envs="sync-guard"
        case "$name" in
        infra) envs="sync-guard sync plan production" ;;
        ai | apis | dcp | website) envs="sync-guard production" ;;
        esac
        for env in $envs; do
            put "repos/$slug/environments/$env" "{\"name\":\"$env\",\"protection_rules\":[{\"type\":\"branch_policy\"}],\"deployment_branch_policy\":{\"protected_branches\":false,\"custom_branch_policies\":true}}"
            put "repos/$slug/environments/$env/deployment-branch-policies" '{"branch_policies":[{"id":1,"name":"main","type":"branch"}]}'
        done
        put "repos/$slug/environments" "$(for env in $envs; do printf '{"name":"%s"}\n' "$env"; done | jq -s '{environments: .}')"
    done
    put "repos/$OWNER/infra/actions/variables" '{"variables":[{"name":"WIF_PROVIDER"},{"name":"WIF_PLAN_SA"},{"name":"WIF_APPLY_SA"}]}'
    echo 1000 >"$STATE/next_id"
}

failures=0

# run <args...>: runs the script on the current state with a fresh log,
# leaving $status, $out and $calls.
run() {
    : >"$STUB_LOG"
    set +e
    out="$("$REPO/scripts/setup-github-repos.sh" "$@" 2>&1 </dev/null)"
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
        failures=$((failures + 1))
    fi
}
is() { [ "$1" = "$2" ] && echo true || echo false; }
says() { [[ "$out" == *"$1"* ]] && echo true || echo false; }
lacks() { [[ "$calls" != *"$1"* ]] && echo true || echo false; }
count() { grep -cE -e "$1" "$STUB_LOG" || true; }
# state <path> <jq>: a jq query on one stub state file, compact.
state() { jq -c "$2" "$STATE/$(printf '%s' "$1" | tr '/' '_').json" 2>/dev/null || echo absent; }
# ruleset <repo> <name>: that ruleset's state file content.
ruleset() {
    local id
    id="$(state "repos/$OWNER/$1/rulesets" ".[] | select(.name == \"$2\") | .id")"
    if [ -z "$id" ] || [ "$id" = absent ]; then echo absent; else state "repos/$OWNER/$1/rulesets/$id" .; fi
}
rule() { printf '%s' "$(ruleset "$1" "$2")" | jq -c "$3"; }

# 1. A dry run (the default) reads, writes nothing, and reports what is
# missing: here site-qa.
seed
rm "$STATE/repos_${OWNER}_site-qa.json"
run
check "dry run exits 0" "$(is "$status" 0)"
check "dry run makes no write" "$(is "$(count '[-]-method')" 0)"
check "dry run reports the missing repo" "$(says "PRECONDITION  $OWNER/site-qa does not exist")"
check "dry run prints the main retarget" "$(says "DRY-RUN: gh api --method PUT repos/$OWNER/infra/rulesets/101")"
check "dry run prints the default branch move" "$(says "DRY-RUN: gh api --method PATCH repos/$OWNER/apis -f default_branch=dev")"

# 2. --apply writes nothing while a precondition is unmet.
run --apply
check "apply with a missing repo exits 1" "$(is "$status" 1)"
check "apply with a missing repo writes nothing" "$(is "$(count '[-]-method')" 0)"
seed
rm "$STATE/repos_${OWNER}_pipelines_branches_dev.json"
run --apply
check "apply without a dev branch exits 1" "$(is "$status" 1)"
check "apply without a dev branch names it" "$(says "$OWNER/pipelines has no 'dev' branch")"
check "apply without a dev branch writes nothing" "$(is "$(count '[-]-method')" 0)"

# 3. --apply converges every repo and reads it back.
seed
run --apply
check "apply exits 0" "$(is "$status" 0)"
check "apply says infra's repo-level WIF values remain" "$(says "infra's repo-level WIF values remain until its environments hold their own")"
covered=0
for name in $all; do
    check "$name main ruleset targets refs/heads/main" "$(is "$(rule "$name" main '.conditions.ref_name.include')" '["refs/heads/main"]')"
    check "$name main ruleset lets jm-rivera bypass by pull request" "$(is "$(rule "$name" main '.bypass_actors')" '[{"actor_type":"User","actor_id":7374450,"bypass_mode":"pull_request"}]')"
    check "$name main ruleset needs one approval, merge commits only" "$(is "$(rule "$name" main '.rules[] | select(.type == "pull_request") | .parameters | [.required_approving_review_count, .require_last_push_approval, .allowed_merge_methods]')" '[1,true,["merge"]]')"
    covered=$((covered + 1))
done
check "covered 11 repos (covered $covered)" "$(is "$covered" 11)"
checks() { rule "$1" "$2" '[.rules[] | select(.type == "required_status_checks") | .parameters | .strict_required_status_checks_policy, [.required_status_checks[] | .context, .integration_id]]'; }
check "infra main requires fmt and the prod plan, not strict, from Actions" "$(is "$(checks infra main)" '[false,["terraform fmt check",15368,"Prod changed stacks planned",15368]]')"
check "apis main requires no check" "$(is "$(checks apis main)" '[]')"
check "infra dev requires its three checks, no approval, no bypass" "$(is "$(checks infra dev)|$(rule infra dev '[(.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count), .bypass_actors]')" '[false,["Changed stacks planned",15368,"terraform fmt check",15368,"Prod pin placeholder unchanged",15368]]|[0,[]]')"
check "apis dev mirrors ONEcampaign dfo-apis dev" "$(is "$(checks apis dev)|$(rule apis dev '.rules[] | select(.type == "pull_request") | .parameters | [.required_approving_review_count, .required_review_thread_resolution]')" '[false,["lint",15368,"test",15368,"docker",15368]]|[0,true]')"
check "website dev mirrors ONEcampaign dfo-website staging" "$(is "$(checks website dev)" '[false,["ci",15368]]')"
check "pipelines dev mirrors ONEcampaign protect-develop" "$(is "$(checks pipelines dev)|$(rule pipelines dev '[(.rules[] | select(.type == "pull_request") | .parameters | .required_approving_review_count, .allowed_merge_methods), .bypass_actors[0].actor_type]')" '[true,["lint",15368,"test",15368]]|[1,["squash","rebase"],"RepositoryRole"]')"
check "dcp dev blocks deletion and force pushes only" "$(is "$(rule dcp dev '[.rules[].type]')" '["deletion","non_fast_forward"]')"
check "site-qa has no dev ruleset" "$(is "$(ruleset site-qa dev)" absent)"
envstate() { state "repos/$OWNER/$1/environments/$2" '[([.protection_rules[] | select(.type == "required_reviewers") | .reviewers[].reviewer.id]), (.deployment_branch_policy != null)]'; }
policy() { state "repos/$OWNER/$1/environments/$2/deployment-branch-policies" '[.branch_policies[].name]'; }
check "infra dev-plan: no reviewers, no branch policy" "$(is "$(envstate infra dev-plan)" '[[],false]')"
check "infra dev: dev only" "$(is "$(envstate infra dev)|$(policy infra dev)" '[[],true]|["dev"]')"
check "infra plan: release reviews, main only" "$(is "$(envstate infra plan)|$(policy infra plan)" '[[19851660],true]|["main"]')"
check "infra production: release reviews, main only" "$(is "$(envstate infra production)|$(policy infra production)" '[[19851660],true]|["main"]')"
for name in ai apis dcp website; do
    check "$name dev: dev only" "$(is "$(envstate "$name" dev)|$(policy "$name" dev)" '[[],true]|["dev"]')"
    check "$name production: release reviews, main only" "$(is "$(envstate "$name" production)|$(policy "$name" production)" '[[19851660],true]|["main"]')"
done
check "docs docsync: dev only" "$(is "$(envstate docs docsync)|$(policy docs docsync)" '[[],true]|["dev"]')"
check "no sync, sync-guard or staging environment remains" "$(is "$(cat "$STATE"/*_environments.json | jq -s -c '[.[].environments[].name | select(. == "sync" or . == "sync-guard" or . == "staging")]')" '[]')"
defaults=""
for name in $all; do defaults="$defaults $name=$(state "repos/$OWNER/$name" .default_branch | tr -d '"')"; done
check "default branches moved" "$(is "$defaults" " infra=main dcp=dev apis=dev ai=dev website=dev pipelines=dev docs=dev ontology=dev spec-kit=dev skills=dev site-qa=main")"
first_patch="$(grep -n -- '--method PATCH' "$STUB_LOG" | head -1 | cut -d: -f1)"
last_main="$(grep -n -- '--method PUT repos/[^ ]*/rulesets/1[0-9][0-9] ' "$STUB_LOG" | tail -1 | cut -d: -f1)"
check "every main ruleset is retargeted before any default branch moves" "$([ -n "$first_patch" ] && [ -n "$last_main" ] && [ "$last_main" -lt "$first_patch" ] && echo true || echo false)"
check "infra's repo-level WIF values stay while its environments lack them" "$(is "$(state "repos/$OWNER/infra/actions/variables" '[.variables[].name]')" '["WIF_PROVIDER","WIF_PLAN_SA","WIF_APPLY_SA"]')"
check "the run names the missing environment values" "$(says 'missing: dev-plan:WIF_PROVIDER dev-plan:WIF_PLAN_SA dev:WIF_PROVIDER dev:WIF_APPLY_SA plan:WIF_PROVIDER plan:WIF_PLAN_SA production:WIF_PROVIDER production:WIF_APPLY_SA')"

# 4. A rerun finds nothing to change.
run --apply
check "rerun exits 0" "$(is "$status" 0)"
check "rerun writes nothing" "$(is "$(count '[-]-method')" 0)"

# 5. Once every infra environment holds its values, the repo-level ones go.
for env in dev-plan plan; do put "repos/$OWNER/infra/environments/$env/variables" '{"variables":[{"name":"WIF_PROVIDER"},{"name":"WIF_PLAN_SA"}]}'; done
for env in dev production; do put "repos/$OWNER/infra/environments/$env/variables" '{"variables":[{"name":"WIF_PROVIDER"},{"name":"WIF_APPLY_SA"}]}'; done
run --apply
check "apply with the contract in place exits 0" "$(is "$status" 0)"
check "repo-level WIF values are deleted" "$(is "$(state "repos/$OWNER/infra/actions/variables" '.variables')" '[]')"
check "and read back as gone" "$(says "PASS  $OWNER/infra: no repo-level WIF value.")"
check "the run says every setting read back" "$(says 'every setting read back as set')"

# 6. A ruleset that drifted is replaced on the next run, and a write
# GitHub does not keep ($STUB_DROP) fails the read-back.
sed -i.bak 's/"refs\/heads\/main"/"~DEFAULT_BRANCH"/' "$STATE/repos_${OWNER}_ontology_rulesets_108.json"
run --apply
check "a drifted ruleset is replaced" "$(says "Replacing the 'main' ruleset (108) on $OWNER/ontology")"
check "and reads back" "$(is "$status" 0)"
sed -i.bak 's/"refs\/heads\/main"/"~DEFAULT_BRANCH"/' "$STATE/repos_${OWNER}_ontology_rulesets_108.json"
export STUB_DROP="repos/$OWNER/ontology/rulesets/108"
run --apply
unset STUB_DROP
check "a write that did not take exits 1" "$(is "$status" 1)"
check "and names the ruleset" "$(says "FAIL  $OWNER/ontology: 'main' ruleset differs")"

run --help
check "--help exits 0 and prints usage" "$([ "$status" -eq 0 ] && [[ "$out" == *"Usage: scripts/setup-github-repos.sh"* ]] && echo true || echo false)"
run --force
check "unknown option exits 1 with no gh call" "$([ "$status" -eq 1 ] && [ -z "$calls" ] && echo true || echo false)"

if [ "$failures" -eq 0 ]; then
    echo "All scenarios passed."
else
    echo "$failures check(s) failed."
    exit 1
fi
