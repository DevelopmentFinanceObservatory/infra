#!/usr/bin/env bash
# Set the GitHub App credentials the workflows in one GitHub org read, and
# create the environments that hold the release App's credentials or bind
# infra's Terraform identities.
#
# Two Apps mint the tokens these workflows use:
#   dfo-reader   owned by ONEcampaign, contents read on ONEcampaign's dfo
#                repos. Its READER_APP_CLIENT_ID variable and
#                READER_APP_PRIVATE_KEY secret go wherever a workflow mints
#                a reader token, as READER_REPOS below lists. In dfo-dev
#                that is repo level. In dfo-prod it is environments only,
#                each admitting only `main`: `sync-guard` on all ten repos,
#                `sync` and `plan` on infra, and `production` on ai and
#                apis. No prod repo holds it at repo level.
#   dfo-release  owned by DevelopmentFinanceObservatory, installed on its
#                ten repos, prod writes only. Its RELEASE_APP_CLIENT_ID
#                variable and RELEASE_APP_PRIVATE_KEY secret live in
#                environments, so only a job that declares one can mint it:
#                `sync-guard` on all ten repos, `sync` on infra, and
#                `production` on dcp. Each of these admits only `main`.
# Dev writes keep the existing dfo-bot App, which this script leaves alone.
#
# In dfo-prod it also creates infra's `plan` and `production`, admitting
# only `main`; `plan` holds the reader pair and `production` no value. The
# foundation stack binds the prod planner to `plan` on main and the prod
# applier to `production` on main, so plan-prod.yml's plan job, which runs
# PR code, never presents a token the applier accepts.
#
# This is the one place these values and the non-deploy environments are
# set. scripts/handoff.sh sets each service repo's deploy values and creates
# its deploy environment; `production` on ai, apis and dcp is one of
# those. Both scripts
# create and restrict environments through converge_branch_policy in
# scripts/github-environment.sh, which leaves `production` restricted to
# `main` whichever runs first, and neither removes the other's values.
#
# Repo names come from org_repos and org_repo in scripts/deploy-targets.sh.
# Every input is checked, and every environment converged, before any value
# is written. A key is sent to gh on stdin and never printed.
#
# Usage: scripts/setup-github-apps.sh <env> [options]
#   scripts/setup-github-apps.sh dfo-dev --reader-key ~/keys/dfo-reader.pem --reader-client-id Iv23liAbc
#   scripts/setup-github-apps.sh dfo-prod --dry-run
#
#   <env>                     dfo-dev (ONEcampaign) or dfo-prod (DevelopmentFinanceObservatory)
#   --reader-key PATH         dfo-reader's private key (.pem)
#   --reader-client-id ID     dfo-reader's client ID (starts with Iv)
#   --release-key PATH        dfo-release's private key, dfo-prod only
#   --release-client-id ID    dfo-release's client ID, dfo-prod only
#   --dry-run                 run the reads and print every gh write without making it
#   -h, --help                print this help
#
# A missing option is prompted for on a terminal, and fails the run
# otherwise.
set -euo pipefail

print_usage() {
    sed -n '/^# Usage:/,/^# otherwise\.$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Where the dfo-reader pair goes, by repo short name: yes or no for a
# repo-level pair in dfo-dev, then the comma-separated environments that
# hold it in dfo-prod, then the workflows that mint it. Every new-org repo
# runs sync-guard.yml, which reads the reader key too, so every dfo-prod
# row names sync-guard. A dfo-prod PR job never mints a reader token, so
# each prod placement is an environment a main-only job declares. Grep the
# repos' .github directories for READER_APP_ after adding or removing a
# mint.
READER_REPOS="
ai         yes  sync-guard,production  ci.yml build-deploy.yml sync-guard.yml
apis       yes  sync-guard,production  ci.yml deploy.yml migrations.yml bundle-round-trip.yml code-index-live.yml eval-gate.yml full-grids.yml sdmx-live.yml actions/spec-kit-auth sync-guard.yml
docs       yes  sync-guard             build.yml registry-health.yml sync-guard.yml
pipelines  yes  sync-guard             ci.yml sync-guard.yml
infra      no   sync-guard,sync,plan   sync.yml plan-prod.yml sync-guard.yml
dcp        no   sync-guard             sync-guard.yml
website    no   sync-guard             sync-guard.yml
ontology   no   sync-guard             sync-guard.yml
spec-kit   no   sync-guard             sync-guard.yml
skills     yes  sync-guard             validate-skills.yml sync-guard.yml
"

dfo_env="" reader_key="" reader_id="" release_key="" release_id="" dry_run=false
while [ $# -gt 0 ]; do
    case "$1" in
    -h | --help)
        print_usage
        exit 0
        ;;
    --dry-run) dry_run=true ;;
    --reader-key | --reader-client-id | --release-key | --release-client-id)
        if [ $# -lt 2 ] || [ -z "$2" ]; then
            echo "ERROR: $1 needs a value." >&2
            exit 1
        fi
        case "$1" in
        --reader-key) reader_key="$2" ;;
        --reader-client-id) reader_id="$2" ;;
        --release-key) release_key="$2" ;;
        --release-client-id) release_id="$2" ;;
        esac
        shift
        ;;
    -*)
        echo "Unrecognized option: $1" >&2
        print_usage >&2
        exit 1
        ;;
    *)
        if [ -n "$dfo_env" ]; then
            echo "ERROR: unexpected argument '$1'; the environment is already '$dfo_env'." >&2
            exit 1
        fi
        dfo_env="$1"
        ;;
    esac
    shift
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091 # dynamic paths; both files live beside this script
source "$repo_root/scripts/deploy-targets.sh"
# shellcheck disable=SC1091
source "$repo_root/scripts/github-environment.sh"

if [ -z "$dfo_env" ] || ! org_repos "$dfo_env" >/dev/null; then
    echo "ERROR: unknown environment '$dfo_env' (expected dfo-dev or dfo-prod)." >&2
    print_usage >&2
    exit 1
fi
if [ "$dfo_env" = dfo-dev ] && [ -n "$release_key$release_id" ]; then
    echo "ERROR: dfo-dev takes no release App credentials; dev writes use the dfo-bot App." >&2
    exit 1
fi

# ask <value> <option> <prompt>: prints <value>, or prompts for it on a
# terminal. Fails naming <option> when stdin is not a terminal.
ask() {
    local value="$1" option="$2" prompt="$3"
    if [ -z "$value" ]; then
        if [ ! -t 0 ]; then
            echo "ERROR: missing $option, and stdin is not a terminal to prompt on." >&2
            return 1
        fi
        read -r -p "$prompt: " value
        if [ -z "$value" ]; then
            echo "ERROR: no value given for $option." >&2
            return 1
        fi
    fi
    printf '%s' "$value"
}

# check_key <path> <option>: prints the path, with a leading ~/ expanded,
# once it names a readable PEM private key. Reads only the first line.
check_key() {
    local path="$1" option="$2" first
    # A prompted path arrives with its ~ unexpanded.
    # shellcheck disable=SC2088 # matching a literal ~ is the point
    case "$path" in "~/"*) path="$HOME/${path#\~/}" ;; esac
    if [ ! -f "$path" ] || [ ! -r "$path" ]; then
        echo "ERROR: $option '$path' is not a readable file." >&2
        return 1
    fi
    IFS= read -r first <"$path" || true
    case "$first" in
    "-----BEGIN RSA PRIVATE KEY-----" | "-----BEGIN PRIVATE KEY-----") ;;
    *)
        echo "ERROR: $option '$path' does not start with a PEM private key header." >&2
        return 1
        ;;
    esac
    printf '%s' "$path"
}

# check_client_id <id> <option>: GitHub App client IDs start with Iv. The
# numeric App ID is the likeliest wrong paste, and the token action no
# longer accepts it.
check_client_id() {
    case "$1" in
    Iv*) ;;
    *)
        echo "ERROR: $2 '$1' is not a GitHub App client ID (they start with Iv; the numeric App ID is a different value)." >&2
        return 1
        ;;
    esac
    case "$1" in
    *[!A-Za-z0-9.]*)
        echo "ERROR: $2 '$1' has characters a client ID never contains." >&2
        return 1
        ;;
    esac
    printf '%s' "$1"
}

reader_key="$(ask "$reader_key" --reader-key "Path to dfo-reader's private key")"
reader_key="$(check_key "$reader_key" --reader-key)"
reader_id="$(ask "$reader_id" --reader-client-id "dfo-reader's client ID")"
reader_id="$(check_client_id "$reader_id" --reader-client-id)"
if [ "$dfo_env" = dfo-prod ]; then
    release_key="$(ask "$release_key" --release-key "Path to dfo-release's private key")"
    release_key="$(check_key "$release_key" --release-key)"
    release_id="$(ask "$release_id" --release-client-id "dfo-release's client ID")"
    release_id="$(check_client_id "$release_id" --release-client-id)"
fi

release_branch=main

# The reader placements for this environment, as <owner>/<repo> lines in
# dfo-dev (repo level) and <owner>/<repo> <environment> lines in dfo-prod.
# A prod `production` must be that repo's deploy environment from
# scripts/deploy-targets.sh, deploying from main.
reader_targets=""
while read -r name dev prod _; do
    [ -z "$name" ] && continue
    # A plain assignment, so a name missing from org_repos stops the run.
    slug="$(org_repo "$dfo_env" "$name")" || {
        echo "ERROR: READER_REPOS names '$name', which org_repos in scripts/deploy-targets.sh does not list." >&2
        exit 1
    }
    case "$dfo_env" in
    dfo-dev)
        [ "$dev" = yes ] && reader_targets="${reader_targets}${slug}"$'\n'
        ;;
    dfo-prod)
        for env in ${prod//,/ }; do
            if [ "$env" = production ]; then
                load_deploy_target "$dfo_env" "$name" || exit 1
                if [ "$DEPLOY_GH_ENV $DEPLOY_BRANCH" != "production $release_branch" ]; then
                    echo "ERROR: $name deploys in '$DEPLOY_GH_ENV' from '$DEPLOY_BRANCH' in $dfo_env, but the reader pair would go in 'production' admitting only '$release_branch'." >&2
                    exit 1
                fi
            fi
            reader_targets="${reader_targets}${slug} ${env}"$'\n'
        done
        case ",$prod," in
        *,sync-guard,*) ;;
        *)
            echo "ERROR: READER_REPOS gives $name no sync-guard environment in dfo-prod." >&2
            exit 1
            ;;
        esac
        ;;
    esac
done <<<"$READER_REPOS"

# The release environments, as <owner>/<repo> <environment> lines. Every
# one admits only main: sync-guard runs on pull_request_target, whose ref is
# the base branch, and sync and the dcp prod deploy run from main.
# infra_envs, in the same shape, are infra's planner and applier
# environments, which also admit only main and hold no release value.
release_envs=""
infra_envs=""
if [ "$dfo_env" = dfo-prod ]; then
    infra_envs="$(org_repo "$dfo_env" infra) plan"$'\n'"$(org_repo "$dfo_env" infra) production"$'\n'
    for name in $(org_repos "$dfo_env"); do
        release_envs="${release_envs}$(org_repo "$dfo_env" "$name") sync-guard"$'\n'
    done
    release_envs="${release_envs}$(org_repo "$dfo_env" infra) sync"$'\n'
    load_deploy_target "$dfo_env" dcp || exit 1
    if [ "$DEPLOY_BRANCH" != "$release_branch" ]; then
        echo "ERROR: dcp deploys from '$DEPLOY_BRANCH' in $dfo_env, but its environment here would admit only '$release_branch'." >&2
        exit 1
    fi
    release_envs="${release_envs}${DEPLOY_REPO} ${DEPLOY_GH_ENV}"$'\n'
fi

reader_count="$(printf '%s' "$reader_targets" | grep -c . || true)"
env_count="$(printf '%s' "$release_envs" | grep -c . || true)"
if [ "$reader_count" -eq 0 ]; then
    echo "ERROR: no reader repos resolved for $dfo_env." >&2
    exit 1
fi
infra_env_count="$(printf '%s' "$infra_envs" | grep -c . || true)"
if [ "$dfo_env" = dfo-prod ] && [ "$env_count" -eq 0 ]; then
    echo "ERROR: no release environments resolved for $dfo_env." >&2
    exit 1
fi
if [ "$dfo_env" = dfo-prod ] && [ "$infra_env_count" -ne 2 ]; then
    echo "ERROR: resolved $infra_env_count infra environments for $dfo_env, expected plan and production." >&2
    exit 1
fi

command -v gh >/dev/null || { echo "gh CLI not found. Install: https://cli.github.com" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Not logged in to GitHub. Run 'gh auth login'." >&2; exit 1; }

if [ "$dry_run" = true ]; then
    export GH_DRY_RUN=true
    echo ">> Dry run: reads run, writes are printed and not made."
fi

# Every repo must exist before anything is written, or a typo in a table
# would surface halfway through.
all_repos="$(printf '%s%s' "$reader_targets" "$release_envs" | awk 'NF { print $1 }' | sort -u)"
while read -r slug; do
    [ -z "$slug" ] && continue
    gh api "repos/$slug" --silent || {
        echo "ERROR: cannot read $slug. Check the name and your access." >&2
        exit 1
    }
done <<<"$all_repos"

# Each environment once, in first-seen order: the reader, release and infra
# lists share sync-guard, sync and plan.
all_envs="$(printf '%s%s%s' "$reader_targets" "$release_envs" "$infra_envs" | awk 'NF == 2 && !seen[$0]++')"
while read -r slug env; do
    [ -z "$slug" ] && continue
    converge_branch_policy "$slug" "$env" "$release_branch" || exit 1
done <<<"$all_envs"

while read -r slug env; do
    [ -z "$slug" ] && continue
    if [ -n "$env" ]; then
        echo ">> Setting READER_APP_CLIENT_ID and READER_APP_PRIVATE_KEY in '$env' on $slug..."
        gh_write variable set READER_APP_CLIENT_ID --env "$env" --repo "$slug" --body "$reader_id"
        GH_STDIN_FROM="$reader_key" gh_write secret set READER_APP_PRIVATE_KEY --env "$env" --repo "$slug"
    else
        echo ">> Setting READER_APP_CLIENT_ID and READER_APP_PRIVATE_KEY on $slug..."
        gh_write variable set READER_APP_CLIENT_ID --repo "$slug" --body "$reader_id"
        GH_STDIN_FROM="$reader_key" gh_write secret set READER_APP_PRIVATE_KEY --repo "$slug"
    fi
done <<<"$reader_targets"

while read -r slug env; do
    [ -z "$slug" ] && continue
    echo ">> Setting RELEASE_APP_CLIENT_ID and RELEASE_APP_PRIVATE_KEY in '$env' on $slug..."
    gh_write variable set RELEASE_APP_CLIENT_ID --env "$env" --repo "$slug" --body "$release_id"
    GH_STDIN_FROM="$release_key" gh_write secret set RELEASE_APP_PRIVATE_KEY --env "$env" --repo "$slug"
done <<<"$release_envs"

if [ "$dfo_env" = dfo-prod ]; then
    reader_where="in $reader_count environments"
    infra_note=" Every environment admits only $release_branch, infra's plan and production included."
else
    reader_where="on $reader_count repos"
    infra_note=""
fi
echo ""
if [ "$dry_run" = true ]; then
    echo "Dry run done. A real run would set the reader pair $reader_where and the release pair in $env_count environments.$infra_note"
else
    echo "Done. The reader pair is set $reader_where and the release pair in $env_count environments.$infra_note"
fi
