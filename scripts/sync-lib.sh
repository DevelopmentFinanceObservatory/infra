# shellcheck shell=bash
# The SYNC_* variables are read by the scripts that source this file.
# shellcheck disable=SC2034

# Shared helpers for the release sync from ONEcampaign into the
# DevelopmentFinanceObservatory repos. Sourced by sync-tree.sh,
# sync-release.sh, sync-guard.sh, and push-first-snapshot.sh, so the repo
# table, the excluded path, the release-control paths, and the reachability
# and floor rules live in one place.
#
# Set SYNC_GITHUB_URL to point the git URLs somewhere other than
# https://github.com. The tests use it to serve local repos.

SYNC_SOURCE_OWNER="ONEcampaign"
SYNC_TARGET_OWNER="DevelopmentFinanceObservatory"
SYNC_GITHUB_URL="${SYNC_GITHUB_URL:-https://github.com}"

# The only author and committer whose image-pin PRs sync-guard.sh admits.
SYNC_PIN_AUTHOR="dfo-release[bot]"

# The one line an image-pin PR may change in an excluded path, as dfo-dcp's
# build-and-pin.yml writes it: the key, then an Artifact Registry digest in
# quotes. A tag never matches.
SYNC_PIN_KEY="datacommons_services_image"
SYNC_PIN_VALUE_RE='^[a-z0-9-]+-docker\.pkg\.dev/[a-z0-9-]+/[a-z0-9_-]+/dfo-services-image@sha256:[0-9a-f]{64}$'

# One row per target repo: target name, source repo, source branch, and the
# paths kept from the target's own main ("-" for none). Prod's dcp build
# writes infra's excluded path in the new org, so a sync never overwrites it.
SYNC_TABLE='infra     dfo-infra     main     infra/dfo-prod/dcp/image.auto.tfvars
dcp       dfo-dcp       dev      -
apis      dfo-apis      dev      -
ai        dfo-ai        dev      -
website   dfo-website   staging  -
pipelines dfo-pipelines develop  -
docs      dfo-docs      main     -
ontology  dfo-ontology  main     -
spec-kit  dfo-spec-kit  main     -
skills    dfo-skills    main     -'

# Release-control paths: the files that admit and open sync PRs. A sync
# replaces the whole tree, so releasing a commit from before the newest
# change to one of them would put back an older guard, or delete it. Every
# repo carries sync-guard.yml, and infra also carries the release workflow,
# the guard action, and the sync scripts. Each entry is a git pathspec.
SYNC_CONTROL_PATHS='.github/workflows/sync-guard.yml'
SYNC_INFRA_CONTROL_PATHS='.github/workflows/sync.yml .github/workflows/plan-prod.yml .github/actions/sync-guard scripts/sync-*.sh :(exclude)scripts/*.test.sh'

# _sync_set_row sets SYNC_TARGET, SYNC_SOURCE, SYNC_BRANCH, SYNC_EXCLUDES,
# SYNC_CONTROLS and SYNC_SOURCE_REF from one table row.
_sync_set_row() {
    local excludes
    read -r SYNC_TARGET SYNC_SOURCE SYNC_BRANCH excludes <<<"$1"
    SYNC_EXCLUDES=""
    [ "$excludes" = "-" ] || SYNC_EXCLUDES="$excludes"
    SYNC_CONTROLS="$SYNC_CONTROL_PATHS"
    [ "$SYNC_TARGET" != "infra" ] || SYNC_CONTROLS="$SYNC_CONTROLS $SYNC_INFRA_CONTROL_PATHS"
    SYNC_SOURCE_REF="refs/source/$SYNC_BRANCH"
}

# sync_lookup_target <target> sets the SYNC_* row variables for a target
# repo name such as "apis".
sync_lookup_target() {
    local row
    row="$(awk -v name="$1" '$1 == name' <<<"$SYNC_TABLE")"
    if [ -z "$row" ]; then
        echo "Unknown target repo: $1" >&2
        return 1
    fi
    _sync_set_row "$row"
}

# sync_lookup_source <source> sets the SYNC_* row variables for a source
# repo name such as "dfo-apis".
sync_lookup_source() {
    local row
    row="$(awk -v name="$1" '$2 == name' <<<"$SYNC_TABLE")"
    if [ -z "$row" ]; then
        echo "Unknown source repo: $1" >&2
        return 1
    fi
    _sync_set_row "$row"
}

sync_source_url() { echo "$SYNC_GITHUB_URL/$SYNC_SOURCE_OWNER/$SYNC_SOURCE.git"; }
sync_target_url() { echo "$SYNC_GITHUB_URL/$SYNC_TARGET_OWNER/$SYNC_TARGET.git"; }

# sync_git_auth <token> prints git -c arguments that send the token as basic
# auth to github.com only. Prints nothing for an empty token.
sync_git_auth() {
    [ -n "$1" ] || return 0
    printf '%s\n' "-c" "http.https://github.com/.extraheader=AUTHORIZATION: basic $(printf 'x-access-token:%s' "$1" | base64 | tr -d '\n')"
}

# sync_fetch <url> <token> <object>... fetches each named commit, at depth 1,
# into the repo in the current directory.
sync_fetch() {
    local url="$1" token="$2" auth=()
    shift 2
    while IFS= read -r arg; do auth+=("$arg"); done < <(sync_git_auth "$token")
    git ${auth[@]+"${auth[@]}"} fetch --quiet --no-tags --depth=1 "$url" "$@"
}

# sync_fetch_source <token> [<object>...] fetches the source branch with its
# whole history into SYNC_SOURCE_REF, and each named commit, into the repo in
# the current directory. sync_check_floor needs the whole history.
sync_fetch_source() {
    local token="$1" auth=()
    shift
    while IFS= read -r arg; do auth+=("$arg"); done < <(sync_git_auth "$token")
    git ${auth[@]+"${auth[@]}"} fetch --quiet --no-tags "$(sync_source_url)" \
        "+refs/heads/$SYNC_BRANCH:$SYNC_SOURCE_REF" "$@"
}

# sync_check_floor <sha> succeeds when <sha> is the floor commit or one of
# its descendants. The floor is the newest commit on SYNC_SOURCE_REF that
# touched a path in SYNC_CONTROLS. Refuses, on stderr, when <sha> is older,
# when no commit touched a control path, or when the branch's history here
# is cut short by a shallow fetch. Run inside the repo sync_fetch_source
# filled.
sync_check_floor() {
    local sha="$1" shallow floor paths
    # read keeps each pathspec's glob for git to match.
    read -ra paths <<<"$SYNC_CONTROLS"
    shallow="$(git rev-parse --git-path shallow)"
    if [ -s "$shallow" ] && git rev-list "$SYNC_SOURCE_REF" | grep -qxFf "$shallow"; then
        echo "The history of $SYNC_SOURCE_OWNER/$SYNC_SOURCE's $SYNC_BRANCH branch is shallow here, so its release floor cannot be computed." >&2
        return 1
    fi
    floor="$(git log -1 --format=%H "$SYNC_SOURCE_REF" -- "${paths[@]}")" || {
        echo "The release floor of $SYNC_SOURCE_OWNER/$SYNC_SOURCE's $SYNC_BRANCH branch cannot be computed." >&2
        return 1
    }
    if [ -z "$floor" ]; then
        echo "No commit on $SYNC_SOURCE_OWNER/$SYNC_SOURCE's $SYNC_BRANCH branch touches a release-control path ($SYNC_CONTROLS), so nothing can be released." >&2
        return 1
    fi
    if ! git merge-base --is-ancestor "$floor" "$sha"; then
        echo "$sha is older than $floor, the newest commit on $SYNC_SOURCE_OWNER/$SYNC_SOURCE's $SYNC_BRANCH branch that touches a release-control path. Release $floor or a later commit." >&2
        return 1
    fi
}

# sync_reachable <source> <branch> <sha> succeeds when <sha> is an ancestor
# of, or equal to, the head of <branch> in ONEcampaign/<source>. The compare
# API with the commit as base and the branch as head reports behind_by, the
# count of commits in <sha> that the branch lacks. Needs GH_TOKEN with read
# access to the source repo.
sync_reachable() {
    local behind
    behind="$(gh api "repos/$SYNC_SOURCE_OWNER/$1/compare/$3...$2?per_page=1" --jq .behind_by)" || return 1
    [ "$behind" = "0" ]
}

# sync_parents <commit> prints the commit's parent ids, one per line, from
# the raw commit header, since a depth-1 fetch hides them from rev-parse.
sync_parents() { git cat-file commit "$1" | sed -n '/^$/q; s/^parent //p'; }

# sync_trailer <source> <sha> prints the trailer every synced commit carries.
sync_trailer() { echo "Synced-from: $SYNC_SOURCE_OWNER/$1@$2"; }
