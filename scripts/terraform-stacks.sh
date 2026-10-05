#!/usr/bin/env bash
# Environment and changed-stack resolution for .github/workflows/plan.yml and
# .github/workflows/apply.yml.
#
# Usage:
#   terraform-stacks.sh environment <github-owner>
#     Prints the environment directory under infra/ that this owner's copy of
#     the repo plans and applies: dfo-dev for ONEcampaign, dfo-prod for
#     DevelopmentFinanceObservatory. Any other owner exits 1.
#
#   terraform-stacks.sh changed <environment> [--allow-removed] < changed-paths
#     Reads repository-relative paths, one per line, and prints a compact JSON
#     array of the stacks in infra/<environment> that they change. A stack is
#     a directory under infra/<environment>. It changes when a path falls
#     under infra/stacks/<stack>/, infra/<environment>/<stack>/, or
#     infra/modules/<module>/ for a module the stack calls, directly or
#     through another module. Module calls are read from the stack's own .tf
#     files, symlinks included, so a new module call needs no edit here.
#
#     A path under infra/<environment>/<name>/ where that directory no longer
#     exists means the change removes or renames a stack root, which leaves
#     its resources in state with nothing to plan or apply them. That exits 1
#     naming the stack, unless --allow-removed is given, which reports it and
#     maps the rest. Destroy the stack's resources before removing its root.
#
# Run from the repository root.
set -euo pipefail

fail() {
    echo "terraform-stacks.sh: $*" >&2
    exit 1
}

# annotate <error|warning> <message> prints the message to stderr, as a
# workflow annotation when running in GitHub Actions.
annotate() {
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        echo "::$1::$2" >&2
    else
        echo "terraform-stacks.sh: $1: $2" >&2
    fi
}

environment_for_owner() {
    case "$1" in
        ONEcampaign) echo dfo-dev ;;
        DevelopmentFinanceObservatory) echo dfo-prod ;;
        *) fail "no Terraform environment for repository owner '$1'" ;;
    esac
}

# Local module names a directory's .tf files call, one per line. Matches
# sources such as "../../modules/cloud-run-service" from a stack root and
# "../cloud-run-service" from inside infra/modules. A module whose directory
# no longer exists stays in the list, so a change that deletes it selects the
# stacks that still call it.
module_calls() {
    local dir="$1"
    set -- "$dir"/*.tf
    [ -e "$1" ] || return 0
    grep -ohE 'source[[:space:]]*=[[:space:]]*"(\.\./)+(modules/)?[A-Za-z0-9_-]+"' "$@" |
        sed -E 's#.*/([A-Za-z0-9_-]+)"$#\1#' |
        sort -u
}

# Every module a stack root reaches, one per line.
stack_modules() {
    local seen="" queue next name
    queue="$(module_calls "$1")"
    while [ -n "$queue" ]; do
        next=""
        for name in $queue; do
            case " $seen " in *" $name "*) continue ;; esac
            seen="$seen $name"
            next="$next $(module_calls "infra/modules/$name" | tr '\n' ' ')"
        done
        queue="$(echo "$next" | xargs)"
    done
    # shellcheck disable=SC2086 # word-splitting the space-separated list is intended
    printf '%s\n' $seen
}

# Stack names, one per line, that paths under <root>/<name>/ name but that
# have no directory under <root>.
removed_stacks() {
    local root="$1" path name
    while IFS= read -r path; do
        case "$path" in "$root"/*/*)
            name="${path#"$root"/}"
            name="${name%%/*}"
            [ -d "$root/$name" ] || echo "$name"
            ;;
        esac
    done | sort -u
}

changed_stacks() {
    local root="infra/$1" allow_removed="$2" paths removed name dir stack prefixes module path prefix
    [ -d "$root" ] || fail "environment directory $root does not exist"
    paths="$(cat)"
    removed="$(removed_stacks "$root" <<<"$paths")"
    for name in $removed; do
        if [ "$allow_removed" = "--allow-removed" ]; then
            annotate warning "This change removes the stack root $root/$name. Nothing plans or applies it now, so its resources must already be destroyed."
        else
            annotate error "This change removes the stack root $root/$name, which would leave its resources in state with nothing to manage them. Destroy them first, then add the allow-destroy label to remove the root."
        fi
    done
    if [ -n "$removed" ] && [ "$allow_removed" != "--allow-removed" ]; then
        exit 1
    fi
    for dir in "$root"/*/; do
        [ -d "$dir" ] || continue
        stack="$(basename "$dir")"
        prefixes="infra/stacks/$stack/ $root/$stack/"
        for module in $(stack_modules "$root/$stack"); do
            prefixes="$prefixes infra/modules/$module/"
        done
        while IFS= read -r path; do
            for prefix in $prefixes; do
                case "$path" in "$prefix"*)
                    echo "$stack"
                    continue 3
                    ;;
                esac
            done
        done <<<"$paths"
    done | jq -Rsc 'split("\n") | map(select(. != ""))'
}

[ $# -ge 2 ] || fail "usage: terraform-stacks.sh environment <owner> | changed <environment> [--allow-removed]"
case "$1" in
    environment) environment_for_owner "$2" ;;
    changed)
        case "${3:-}" in "" | --allow-removed) ;; *) fail "unknown option '$3'" ;; esac
        changed_stacks "$2" "${3:-}"
        ;;
    *) fail "unknown command '$1'" ;;
esac
