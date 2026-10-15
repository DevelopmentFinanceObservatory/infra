#!/usr/bin/env bash
# Set the GitHub App credentials the DevelopmentFinanceObservatory workflows
# read. Each App's client ID goes in a `<PREFIX>_CLIENT_ID` variable and its
# private key in a `<PREFIX>_PRIVATE_KEY` secret, in one environment only, so
# only a job that declares that environment, on the one branch it admits,
# can mint the App's token:
#
#   App           Prefix        Repo  Environment  Workflow that mints it
#   dfo-pin       PIN_APP       dcp   dev          deploy-dev.yml, pinning
#                                                  dev images into infra dev
#   dfo-docsync   DOCSYNC_APP   docs  docsync      docsync.yml, opening PRs
#                                                  on apis, ai and skills
#   dfo-release   RELEASE_APP   dcp   production   deploy-prod.yml, pinning
#                                                  prod images into infra main
#
# The environments, their branch policies and their reviewers belong to
# scripts/setup-github-repos.sh. This script checks each target environment
# against scripts/deploy-targets.sh before writing, and refuses a missing or
# mis-restricted one, since a value written to a missing environment would
# create it unrestricted.
#
# Pass the pairs to set; an App left out is left alone, so one App's key can
# be rotated alone. Every input is checked, and every target environment,
# before any value is written. A key is sent to gh on stdin and never
# printed.
#
# Usage: scripts/setup-github-apps.sh [options]
#   scripts/setup-github-apps.sh --pin-key ~/keys/dfo-pin.pem --pin-client-id Iv23liAbc
#   scripts/setup-github-apps.sh --dry-run --release-key ~/keys/dfo-release.pem --release-client-id Iv23liDef
#
#   --pin-key PATH             dfo-pin's private key (.pem)
#   --pin-client-id ID         dfo-pin's client ID (starts with Iv)
#   --docsync-key PATH         dfo-docsync's private key
#   --docsync-client-id ID     dfo-docsync's client ID
#   --release-key PATH         dfo-release's private key
#   --release-client-id ID     dfo-release's client ID
#   --dry-run                  run the reads and print every gh write without making it
#   -h, --help                 print this help
set -euo pipefail

print_usage() {
    sed -n '/^# Usage:/,/^#   -h, --help/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# <app> <prefix> <repo> <environment>, as in the header table.
APPS="
pin      PIN_APP      dcp   dev
docsync  DOCSYNC_APP  docs  docsync
release  RELEASE_APP  dcp   production
"

pin_key="" pin_id="" docsync_key="" docsync_id="" release_key="" release_id="" dry_run=false
while [ $# -gt 0 ]; do
    case "$1" in
    -h | --help)
        print_usage
        exit 0
        ;;
    --dry-run) dry_run=true ;;
    --pin-key | --pin-client-id | --docsync-key | --docsync-client-id | --release-key | --release-client-id)
        if [ $# -lt 2 ] || [ -z "$2" ]; then
            echo "ERROR: $1 needs a value." >&2
            exit 1
        fi
        case "$1" in
        --pin-key) pin_key="$2" ;;
        --pin-client-id) pin_id="$2" ;;
        --docsync-key) docsync_key="$2" ;;
        --docsync-client-id) docsync_id="$2" ;;
        --release-key) release_key="$2" ;;
        --release-client-id) release_id="$2" ;;
        esac
        shift
        ;;
    *)
        echo "Unrecognized argument: $1" >&2
        print_usage >&2
        exit 1
        ;;
    esac
    shift
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091 # dynamic paths; both files live beside this script
source "$repo_root/scripts/deploy-targets.sh"
# shellcheck disable=SC1091
source "$repo_root/scripts/github-environment.sh"

# check_key <path> <option>: prints the path, with a leading ~/ expanded,
# once it names a readable PEM private key. Reads only the first line.
check_key() {
    local path="$1" option="$2" first
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

# The pairs to write, as <prefix> <owner/repo> <environment> <branch>
# <client-id> <key-path> lines. A pair given by half is refused.
writes=""
while read -r app prefix name env; do
    [ -z "$app" ] && continue
    case "$app" in
    pin) key="$pin_key" id="$pin_id" ;;
    docsync) key="$docsync_key" id="$docsync_id" ;;
    release) key="$release_key" id="$release_id" ;;
    esac
    if [ -z "$key$id" ]; then
        continue
    fi
    if [ -z "$key" ] || [ -z "$id" ]; then
        echo "ERROR: give both --$app-key and --$app-client-id, or neither." >&2
        exit 1
    fi
    key="$(check_key "$key" "--$app-key")"
    id="$(check_client_id "$id" "--$app-client-id")"
    branch="$(environment_branch "$name" "$env")" || {
        echo "ERROR: scripts/deploy-targets.sh lists no '$env' environment on $name for $app." >&2
        exit 1
    }
    writes="${writes}${prefix} $(org_repo "$name") ${env} ${branch} ${id} ${key}"$'\n'
done <<<"$APPS"
count="$(printf '%s' "$writes" | grep -c . || true)"
if [ "$count" -eq 0 ]; then
    echo "ERROR: give at least one App's key and client ID." >&2
    print_usage >&2
    exit 1
fi

command -v gh >/dev/null || { echo "gh CLI not found. Install: https://cli.github.com" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Not logged in to GitHub. Run 'gh auth login'." >&2; exit 1; }

if [ "$dry_run" = true ]; then
    export GH_DRY_RUN=true
    echo ">> Dry run: reads run, writes are printed and not made."
fi

echo ">> Checking the target environments..."
ok=true
while read -r prefix slug env branch _; do
    [ -z "$prefix" ] && continue
    check_environment "$slug" "$env" "$branch" || ok=false
done <<<"$writes"
if [ "$ok" != true ]; then
    if [ "$dry_run" = true ]; then
        echo "NOTE: a real run stops here, writing nothing, until scripts/setup-github-repos.sh --apply has fixed the environments above."
    else
        echo "ERROR: fix the environments above with scripts/setup-github-repos.sh --apply; nothing was written." >&2
        exit 1
    fi
fi

while read -r prefix slug env branch id key; do
    [ -z "$prefix" ] && continue
    echo ">> Setting ${prefix}_CLIENT_ID and ${prefix}_PRIVATE_KEY in '$env' on $slug..."
    gh_write variable set "${prefix}_CLIENT_ID" --env "$env" --repo "$slug" --body "$id"
    GH_STDIN_FROM="$key" gh_write secret set "${prefix}_PRIVATE_KEY" --env "$env" --repo "$slug"
done <<<"$writes"

echo ""
if [ "$dry_run" = true ]; then
    echo "Dry run done. A real run would set $count App credential pairs."
else
    echo "Done. Set $count App credential pairs."
fi
