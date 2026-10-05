#!/usr/bin/env bash
# Scenario tests for sync-tree.sh, push-first-snapshot.sh, sync-guard.sh,
# sync-guard-check.sh and sync-release.sh.
# Each scenario builds throwaway git repos under a temp directory. The
# first-snapshot and guard scenarios serve those repos through file:// URLs
# by setting SYNC_GITHUB_URL, and replace gh with a stub that answers the
# compare and commits APIs, records check-run requests, and keeps PR state.
# Run by hand after touching any sync script:
#   scripts/sync-tree.test.sh
# Set SHOW_GUARD_LOG=1 to print each guard verdict and its reason.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIN="infra/dfo-prod/dcp/image.auto.tfvars"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

# Fixed identities, so no scenario depends on the operator's git config.
export GIT_CONFIG_GLOBAL="$ROOT/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name "Sync Operator"
git config --global user.email "operator@example.invalid"
git config --global init.defaultBranch main
git config --global uploadpack.allowAnySHA1InWant true

passed=0
failed=0
check() {
    local description="$1"
    shift
    if "$@"; then
        passed=$((passed + 1))
        echo "ok   $description"
    else
        failed=$((failed + 1))
        echo "FAIL $description"
    fi
}

# mk_tree <repo> <mode|path|content>... writes a tree and prints its id.
# For mode 160000 the content is the gitlink's commit id; for 120000 it is
# the symlink's target. A \n in the content starts a new line.
mk_tree() {
    local repo="$1" index spec mode path content id
    shift
    index="$(mktemp -d)/index"
    for spec in "$@"; do
        IFS='|' read -r mode path content <<<"$spec"
        if [ "$mode" = "160000" ]; then
            id="$content"
        else
            id="$(printf '%b\n' "$content" | git -C "$repo" hash-object -w --stdin)"
        fi
        GIT_INDEX_FILE="$index" git -C "$repo" update-index --add --cacheinfo "$mode,$id,$path"
    done
    GIT_INDEX_FILE="$index" git -C "$repo" write-tree
}

# mk_commit <repo> <tree> <message> [<parent>] prints the new commit's id.
mk_commit() {
    local repo="$1" tree="$2" message="$3"
    git -C "$repo" commit-tree "$tree" -m "$message" ${4:+-p "$4"}
}

# fails <command>... succeeds when the command fails, hiding its stderr.
fails() { ! "$@" 2>/dev/null; }

ls_tree() { git -C "$1" ls-tree -r "$2"; }
same() { [ "$1" = "$2" ]; }

GITLINK="1111111111111111111111111111111111111111"
GUARD_YML=".github/workflows/sync-guard.yml"
SOURCE_ENTRIES=(
    "100644|$GUARD_YML|guard v1"
    "100644|README.md|readme"
    "100755|scripts/run.sh|#!/bin/sh"
    "120000|scripts/link|run.sh"
    "160000|mixer|$GITLINK"
    "100644|$PIN|source pin"
)

echo "sync-tree.sh"
repo="$ROOT/tree"
git init --quiet "$repo"
source_tree="$(mk_tree "$repo" "${SOURCE_ENTRIES[@]}")"
source_commit="$(mk_commit "$repo" "$source_tree" source)"
base_with_pin="$(mk_commit "$repo" "$(mk_tree "$repo" "100644|old.txt|old" "100644|$PIN|base pin")" base)"
base_symlink_pin="$(mk_commit "$repo" "$(mk_tree "$repo" "100644|old.txt|old" "120000|$PIN|../../dfo-dev/dcp/dfo.auto.tfvars")" base)"
base_executable_pin="$(mk_commit "$repo" "$(mk_tree "$repo" "100644|old.txt|old" "100755|$PIN|base pin")" base)"
base_without_pin="$(mk_commit "$repo" "$(mk_tree "$repo" "100644|old.txt|old")" base)"
source_no_pin="$(mk_commit "$repo" "$(mk_tree "$repo" "100644|README.md|readme")" source)"
base_pin_entry="$(git -C "$repo" ls-tree "$base_with_pin" -- "$PIN")"

run_tree() { (cd "$repo" && "$SCRIPT_DIR/sync-tree.sh" "$@"); }
has_entry() { ls_tree "$repo" "$1" | grep -qF "$2"; }

result="$(run_tree infra "$source_commit")"
check "no base: the tree is the source tree whole" same "$result" "$source_tree"
check "file mode 100755 survives" has_entry "$result" "100755 blob"
check "symlink survives" has_entry "$result" "120000 blob"
check "submodule gitlink survives" has_entry "$result" "160000 commit $GITLINK	mixer"

result="$(run_tree infra "$source_commit" "$base_with_pin")"
expected="$( (ls_tree "$repo" "$source_tree" | grep -vF "	$PIN"; echo "$base_pin_entry") | sort -k4)"
check "base has the excluded path: its entry replaces the source's" \
    same "$(ls_tree "$repo" "$result" | sort -k4)" "$expected"
check "base has the excluded path as a symlink: refused" \
    fails run_tree infra "$source_commit" "$base_symlink_pin"
check "base has the excluded path as an executable: refused" \
    fails run_tree infra "$source_commit" "$base_executable_pin"

result="$(run_tree infra "$source_commit" "$base_without_pin")"
check "base lacks the excluded path: the path is removed" \
    same "$(ls_tree "$repo" "$result")" "$(ls_tree "$repo" "$source_tree" | grep -vF "	$PIN")"

result="$(run_tree infra "$source_no_pin" "$base_with_pin")"
check "source lacks the excluded path: base's entry is added" has_entry "$result" "$base_pin_entry"

result="$(run_tree apis "$source_commit" "$base_with_pin")"
check "a target with no excluded paths takes the source tree whole" same "$result" "$source_tree"

printf 'staged\n' >"$repo/staged.txt"
git -C "$repo" add staged.txt
index_before="$(git -C "$repo" ls-files --stage)"
run_tree infra "$source_commit" "$base_with_pin" >/dev/null
check "the caller's index is untouched" same "$(git -C "$repo" ls-files --stage)" "$index_before"

check "an unknown target is refused" fails run_tree nope "$source_commit"

# Served repos for the scenarios below, laid out as owner/name.git.
serve() {
    git init --quiet --bare "$ROOT/srv/$1.git"
    echo "$ROOT/srv/$1.git"
}
export SYNC_GITHUB_URL="file://$ROOT/srv"

echo "push-first-snapshot.sh"
src="$(serve ONEcampaign/dfo-infra)"
tgt="$(serve DevelopmentFinanceObservatory/infra)"
snap_tree="$(mk_tree "$src" "${SOURCE_ENTRIES[@]}")"
snap_sha="$(mk_commit "$src" "$snap_tree" "on main")"
git -C "$src" update-ref refs/heads/main "$snap_sha"
off_branch="$(mk_commit "$src" "$snap_tree" "off main")"
git -C "$src" update-ref refs/heads/feature "$off_branch"

push_cmd="$("$SCRIPT_DIR/push-first-snapshot.sh" dfo-infra "$snap_sha" 2>/dev/null)"
eval "$push_cmd" 2>/dev/null
pushed="$(git -C "$tgt" rev-parse --verify --quiet refs/heads/main || true)"
check "the snapshot lands on main once the printed push runs" test -n "$pushed"
check "the snapshot tree is the source tree" same "$(git -C "$tgt" rev-parse "$pushed^{tree}")" "$snap_tree"
check "the snapshot has no parent" same "$(git -C "$tgt" cat-file commit "$pushed" | grep -c '^parent ')" 0
check "the snapshot message names the source commit" \
    same "$(git -C "$tgt" log -1 --format=%s "$pushed")" "Snapshot of ONEcampaign/dfo-infra@$snap_sha"
check "the snapshot carries the Synced-from trailer" \
    same "$(git -C "$tgt" log -1 --format='%(trailers:key=Synced-from,valueonly)' "$pushed" | sed '/^$/d')" \
    "ONEcampaign/dfo-infra@$snap_sha"
check "the snapshot author comes from git config" \
    same "$(git -C "$tgt" log -1 --format='%an <%ae> / %cn <%ce>' "$pushed")" \
    "Sync Operator <operator@example.invalid> / Sync Operator <operator@example.invalid>"
check "a non-empty target is refused" \
    fails "$SCRIPT_DIR/push-first-snapshot.sh" dfo-infra "$snap_sha"

serve ONEcampaign/dfo-docs >/dev/null
docs_src="$ROOT/srv/ONEcampaign/dfo-docs.git"
serve DevelopmentFinanceObservatory/docs >/dev/null
docs_tree="$(mk_tree "$docs_src" "100644|$GUARD_YML|guard v1" "100644|README.md|docs")"
docs_main="$(mk_commit "$docs_src" "$docs_tree" "on main")"
git -C "$docs_src" update-ref refs/heads/main "$docs_main"
docs_off="$(mk_commit "$docs_src" "$docs_tree" "off main")"
git -C "$docs_src" update-ref refs/heads/feature "$docs_off"
check "a commit off the source branch is refused" \
    fails "$SCRIPT_DIR/push-first-snapshot.sh" dfo-docs "$docs_off"
check "an abbreviated sha is refused" \
    fails "$SCRIPT_DIR/push-first-snapshot.sh" dfo-docs "${docs_main:0:12}"
docs_guard="$(mk_commit "$docs_src" "$(mk_tree "$docs_src" "100644|$GUARD_YML|guard v2" "100644|README.md|docs")" "guard v2" "$docs_main")"
git -C "$docs_src" update-ref refs/heads/main "$docs_guard"
check "a commit older than the release floor is refused" \
    fails "$SCRIPT_DIR/push-first-snapshot.sh" dfo-docs "$docs_main"

serve ONEcampaign/dfo-ontology >/dev/null
serve DevelopmentFinanceObservatory/ontology >/dev/null
ontology_src="$ROOT/srv/ONEcampaign/dfo-ontology.git"
ontology_main="$(mk_commit "$ontology_src" "$(mk_tree "$ontology_src" "100644|README.md|ontology")" "on main")"
git -C "$ontology_src" update-ref refs/heads/main "$ontology_main"
check "a source branch with no release-control commit is refused" \
    fails "$SCRIPT_DIR/push-first-snapshot.sh" dfo-ontology "$ontology_main"

echo "sync-guard.sh"
# gh stub. The compare API answers STUB_BEHIND_BY for a ONEcampaign repo.
# For a DevelopmentFinanceObservatory repo it lists one commit, the compare's
# head, with the author, committer and verified flag from STUB_PIN_AUTHOR,
# STUB_PIN_COMMITTER and STUB_PIN_VERIFIED, or fails when STUB_COMPARE_FAIL
# is set. The commits API answers STUB_SHA, and the pr commands keep their
# state under $ROOT/gh. A
# check-runs call appends "<method> <path> <token>" to $ROOT/gh/checks,
# keeps its body in $ROOT/gh/check-<method>.json, and answers id 42, or
# fails when STUB_CHECKS_FAIL is set.
mkdir -p "$ROOT/bin" "$ROOT/gh"
cat >"$ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
state="$STUB_STATE"
case "$1 $2 $*" in
"api --method"*/check-runs*)
    [ -z "${STUB_CHECKS_FAIL:-}" ] || exit 1
    echo "$3 $4 $GH_TOKEN" >>"$state/checks"
    cat >"$state/check-$3.json"
    [ "$3" = POST ] && echo 42
    exit 0
    ;;
api\ repos/DevelopmentFinanceObservatory/*/compare/*)
    [ -z "${STUB_COMPARE_FAIL:-}" ] || exit 1
    printf '%s\t%s\t%s\t%s\n' "${2##*...}" "${STUB_PIN_AUTHOR:-dfo-release[bot]}" \
        "${STUB_PIN_COMMITTER:-dfo-release[bot]}" "${STUB_PIN_VERIFIED:-true}"
    ;;
api\ repos/*/compare/*) echo "${STUB_BEHIND_BY:-0}" ;;
api\ repos/*/commits/*) echo "$STUB_SHA" ;;
"pr create"*) echo 7 >"$state/pr"; echo "$*" >>"$state/created" ;;
"pr list"*--head*) cat "$state/pr" 2>/dev/null || true ;;
"pr list"*) printf '%s\n' ${STUB_OTHERS:-} ;;
"pr close"*) echo "$3" >>"$state/closed" ;;
*) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
STUB
export STUB_STATE="$ROOT/gh"
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"

# Release a newer source commit onto infra's main, which now holds the pin
# placeholder.
PIN_HEADER="# Machine-owned: written by dfo-dcp's build-and-pin.yml."
DIGEST="$(printf 'a%.0s' $(seq 1 64))"
PIN_VALUE="europe-west1-docker.pkg.dev/prod-fin-observatory/datacommons/dfo-services-image@sha256:$DIGEST"
base="$(mk_commit "$tgt" "$(mk_tree "$tgt" "100644|README.md|readme" "100644|$PIN|$PIN_HEADER\ndatacommons_services_image = null")" "pin" "$pushed")"
git -C "$tgt" update-ref refs/heads/main "$base"
new_tree="$(mk_tree "$src" "100644|$GUARD_YML|guard v1" "100644|README.md|readme v2" "100755|scripts/run.sh|#!/bin/sh" "160000|mixer|$GITLINK" "100644|$PIN|source pin")"
new_sha="$(mk_commit "$src" "$new_tree" "v2" "$snap_sha")"
git -C "$src" update-ref refs/heads/main "$new_sha"
git -C "$tgt" fetch --quiet "$src" "$new_sha"
good_tree="$(cd "$tgt" && "$SCRIPT_DIR/sync-tree.sh" infra "$new_sha" "$base")"

guard() { "$SCRIPT_DIR/sync-guard.sh" infra "$base" "$1" "${2:-someone}" 2>>"$ROOT/guard.log"; }
sync_head() {
    mk_commit "$tgt" "$1" "Sync ONEcampaign/dfo-infra@$new_sha

Synced-from: ${2:-ONEcampaign/dfo-infra@$new_sha}" "$base"
}

guard_unreachable() { STUB_BEHIND_BY=2 guard "$@"; }

head="$(sync_head "$good_tree")"
check "a sync PR with the expected tree passes" guard "$head"
check "a sync PR whose tree overwrites the excluded path fails" fails guard "$(sync_head "$new_tree")"
check "a sync PR whose source commit is off the source branch fails" \
    fails guard_unreachable "$head"
check "a sync PR whose trailer names another source repo fails" \
    fails guard "$(sync_head "$good_tree" "ONEcampaign/dfo-docs@$new_sha")"
check "a sync PR whose trailer has an abbreviated sha fails" \
    fails guard "$(sync_head "$good_tree" "ONEcampaign/dfo-infra@${new_sha:0:12}")"
check "a sync PR with the expected tree on an older main fails" \
    fails guard "$(mk_commit "$tgt" "$good_tree" "Sync

Synced-from: ONEcampaign/dfo-infra@$new_sha" "$pushed")"
check "a sync PR whose head has two parents fails" \
    fails guard "$(git -C "$tgt" commit-tree "$good_tree" -p "$base" -p "$pushed" -m "Merge

Synced-from: ONEcampaign/dfo-infra@$new_sha")"
check "a sync PR whose head has no parent fails" \
    fails guard "$(mk_commit "$tgt" "$good_tree" "Sync

Synced-from: ONEcampaign/dfo-infra@$new_sha")"

# pin_head [<pin entry> [<mode|path|content>...]] commits a pin, by default
# a valid one, plus any extra entries, onto PIN_PARENT or base.
pin_line="datacommons_services_image = \"$PIN_VALUE\""
pin_head() {
    local entry="${1:-100644|$PIN|$PIN_HEADER\n$pin_line}"
    shift || true
    mk_commit "$tgt" "$(mk_tree "$tgt" "100644|README.md|readme" "$entry" "$@")" "pin" "${PIN_PARENT:-$base}"
}
pin_guard() { guard "$1" "dfo-release[bot]"; }
# pin_guard_with <VAR=value> <head> runs pin_guard with one stub setting.
pin_guard_with() { env "$1" "$SCRIPT_DIR/sync-guard.sh" infra "$base" "$2" "dfo-release[bot]" 2>>"$ROOT/guard.log"; }

check "an image-pin PR from the release App passes" pin_guard "$(pin_head)"
check "an image-pin PR opened by anyone else fails" fails guard "$(pin_head)" "someone"
check "an image-pin PR that changes another file fails" \
    fails pin_guard "$(pin_head "" "100644|extra.txt|extra")"
check "an untrailered PR with no change fails" \
    fails pin_guard "$(mk_commit "$tgt" "$(git -C "$tgt" rev-parse "$base^{tree}")" "noop" "$base")"
check "an image-pin PR on an older main fails" fails pin_guard "$(PIN_PARENT="$pushed" pin_head)"
first_pin="$(pin_head)"
check "an image-pin PR of two commits fails" \
    fails pin_guard "$(PIN_PARENT="$first_pin" pin_head "100644|$PIN|$PIN_HEADER\n${pin_line/sha256:a/sha256:b}")"
check "an image-pin PR authored by anyone else fails" \
    fails pin_guard_with STUB_PIN_AUTHOR=someone "$(pin_head)"
check "an image-pin PR committed by anyone else fails" \
    fails pin_guard_with STUB_PIN_COMMITTER=web-flow "$(pin_head)"
check "an image-pin PR with an unverified commit fails" \
    fails pin_guard_with STUB_PIN_VERIFIED=false "$(pin_head)"
check "an image-pin PR whose commits cannot be listed fails" \
    fails pin_guard_with STUB_COMPARE_FAIL=1 "$(pin_head)"
check "an image-pin PR that turns the pin into a symlink fails" \
    fails pin_guard "$(pin_head "120000|$PIN|../../dfo-dev/dcp/dfo.auto.tfvars")"
check "an image-pin PR that makes the pin executable fails" \
    fails pin_guard "$(pin_head "100755|$PIN|$PIN_HEADER\n$pin_line")"
check "an image-pin PR that removes the pin fails" \
    fails pin_guard "$(mk_commit "$tgt" "$(mk_tree "$tgt" "100644|README.md|readme")" "pin" "$base")"
check "an image-pin PR that pins a tag fails" \
    fails pin_guard "$(pin_head "100644|$PIN|$PIN_HEADER\n${pin_line%@sha256:*}:latest\"")"
check "an image-pin PR that also edits the header fails" \
    fails pin_guard "$(pin_head "100644|$PIN|# edited\n$pin_line")"
check "an image-pin PR that adds a second line fails" \
    fails pin_guard "$(pin_head "100644|$PIN|$PIN_HEADER\n$pin_line\nextra = 1")"

# A later pin, on a base that already holds one, keeps base's registry path
# and changes only the digest.
pinned_base="$(mk_commit "$tgt" "$(mk_tree "$tgt" "100644|README.md|readme" "100644|$PIN|$PIN_HEADER\n$pin_line")" "pinned" "$base")"
tag_base="$(mk_commit "$tgt" "$(mk_tree "$tgt" "100644|README.md|readme" "100644|$PIN|$PIN_HEADER\n${pin_line%@sha256:*}:latest\"")" "tagged" "$base")"
# repin <base> <value> commits the pin line set to <value> onto <base>.
repin() { mk_commit "$tgt" "$(mk_tree "$tgt" "100644|README.md|readme" "100644|$PIN|$PIN_HEADER\ndatacommons_services_image = \"$2\"")" "pin" "$1"; }
repin_guard() { "$SCRIPT_DIR/sync-guard.sh" infra "$1" "$2" "dfo-release[bot]" 2>>"$ROOT/guard.log"; }
NEW_DIGEST="$(printf 'b%.0s' $(seq 1 64))"
check "a re-pin that changes only the digest passes" \
    repin_guard "$pinned_base" "$(repin "$pinned_base" "${PIN_VALUE%@sha256:*}@sha256:$NEW_DIGEST")"
check "a re-pin to another project fails" \
    fails repin_guard "$pinned_base" "$(repin "$pinned_base" "europe-west1-docker.pkg.dev/other-project/datacommons/dfo-services-image@sha256:$NEW_DIGEST")"
check "a re-pin to another region fails" \
    fails repin_guard "$pinned_base" "$(repin "$pinned_base" "us-central1-docker.pkg.dev/prod-fin-observatory/datacommons/dfo-services-image@sha256:$NEW_DIGEST")"
check "a re-pin to another repository fails" \
    fails repin_guard "$pinned_base" "$(repin "$pinned_base" "europe-west1-docker.pkg.dev/prod-fin-observatory/other/dfo-services-image@sha256:$NEW_DIGEST")"
check "a pin over a base that holds a tag fails" \
    fails repin_guard "$tag_base" "$(repin "$tag_base" "$PIN_VALUE")"

apis_tgt="$(serve DevelopmentFinanceObservatory/apis)"
apis_base="$(mk_commit "$apis_tgt" "$(mk_tree "$apis_tgt" "100644|a.txt|a")" base)"
apis_head="$(mk_commit "$apis_tgt" "$(mk_tree "$apis_tgt" "100644|a.txt|b")" edit "$apis_base")"
check "an untrailered PR into a repo with no excluded paths fails" \
    fails "$SCRIPT_DIR/sync-guard.sh" apis "$apis_base" "$apis_head" "dfo-release[bot]"

echo "sync-guard-check.sh"
export SYNC_CHECKS_TOKEN="checks-token" GITHUB_SERVER_URL="https://github.example" GITHUB_RUN_ID=99
check_run() {
    rm -f "$ROOT/gh/checks" "$ROOT/gh"/check-*.json
    "$SCRIPT_DIR/sync-guard-check.sh" infra "$base" "$1" someone >/dev/null 2>>"$ROOT/guard.log"
}
body() { jq -r "$2" "$ROOT/gh/check-$1.json"; }
checks_log() { tr '\n' ';' <"$ROOT/gh/checks"; }
check_url="repos/DevelopmentFinanceObservatory/infra/check-runs"

check "a passing guard exits 0" check_run "$head"
check "the check run opens in_progress, then closes, both with the checks token" \
    same "$(checks_log)" "POST $check_url checks-token;PATCH $check_url/42 checks-token;"
check "the opening body names sync-guard, the head sha and in_progress" \
    same "$(body POST '[.name, .head_sha, .status] | join(" ")')" "sync-guard $head in_progress"
check "the opening body links the workflow run" \
    same "$(body POST .details_url)" "https://github.example/DevelopmentFinanceObservatory/infra/actions/runs/99"
check "a pass closes the check run as success" \
    same "$(body PATCH '[.status, .conclusion, .output.title] | join(" ")')" "completed success sync-guard passed"
check "a pass carries the guard's reason as the summary" \
    grep -qF "sync-guard passed: the head tree is ONEcampaign/dfo-infra@$new_sha" <(body PATCH .output.summary)

bad_head="$(sync_head "$new_tree")"
check "a failing guard exits non-zero" fails check_run "$bad_head"
check "a failure still opens the check run on the head sha" same "$(body POST .head_sha)" "$bad_head"
check "a failure closes the check run as failure" \
    same "$(body PATCH '[.status, .conclusion, .output.title] | join(" ")')" "completed failure sync-guard failed"
check "a failure carries the guard's reason as the summary" \
    grep -qF "sync-guard failed for $bad_head: the head tree" <(body PATCH .output.summary)

STUB_CHECKS_FAIL=1 check "a check run that cannot open fails the job" fails check_run "$head"
check "a check run that cannot open is never closed" test ! -e "$ROOT/gh/check-PATCH.json"
unset GITHUB_SERVER_URL GITHUB_RUN_ID

echo "sync-release.sh"
export SYNC_SOURCE_TOKEN="" SYNC_TARGET_TOKEN="" STUB_SHA="$new_sha"
release() { "$SCRIPT_DIR/sync-release.sh" infra 2>/dev/null; }
branch_head() { git -C "$tgt" rev-parse --verify --quiet "refs/heads/sync/infra/$new_sha" || true; }

STUB_OTHERS="3 4" release
first="$(branch_head)"
check "the release pushes sync/<repo>/<sha>" test -n "$first"
check "the release commit holds the tree the guard expects" \
    same "$(git -C "$tgt" rev-parse "$first^{tree}")" "$good_tree"
check "the release commit's parent is main" \
    same "$(git -C "$tgt" cat-file commit "$first" | sed -n 's/^parent //p')" "$base"
check "the release commit carries the Synced-from trailer" \
    same "$(git -C "$tgt" log -1 --format='%(trailers:key=Synced-from,valueonly)' "$first" | sed '/^$/d')" \
    "ONEcampaign/dfo-infra@$new_sha"
check "the release passes the guard" guard "$first"
check "the release opens one PR" same "$(wc -l <"$ROOT/gh/created" | tr -d ' ')" 1
check "the release closes the other open sync PRs" same "$(tr '\n' ' ' <"$ROOT/gh/closed")" "3 4 "

release
check "a re-run keeps the branch's commit" same "$(branch_head)" "$first"
check "a re-run reuses the open PR" same "$(wc -l <"$ROOT/gh/created" | tr -d ' ')" 1

git -C "$tgt" update-ref refs/heads/main "$first"
git -C "$tgt" update-ref -d "refs/heads/sync/infra/$new_sha"
release
check "a commit main already holds releases nothing" same "$(branch_head)" ""

# DevelopmentFinanceObservatory/docs is still empty from the snapshot scenarios.
check "an empty target is refused" fails "$SCRIPT_DIR/sync-release.sh" docs

echo "release floor"
# A later source commit changes the guard workflow, which makes it infra's
# floor and leaves new_sha below it. main goes back to base, where new_sha
# would otherwise release.
git -C "$tgt" update-ref refs/heads/main "$base"
floor_sha="$(mk_commit "$src" "$(mk_tree "$src" "100644|$GUARD_YML|guard v2" "100644|README.md|readme v2" "100755|scripts/run.sh|#!/bin/sh" "160000|mixer|$GITLINK" "100644|$PIN|source pin")" "guard v2" "$new_sha")"
git -C "$src" update-ref refs/heads/main "$floor_sha"
release_sha() { STUB_SHA="$1" "$SCRIPT_DIR/sync-release.sh" infra; }
sync_branch() { git -C "$tgt" rev-parse --verify --quiet "refs/heads/sync/infra/$1" || true; }

release_err="$(release_sha "$new_sha" 2>&1 >/dev/null)" && release_status=0 || release_status=$?
check "a release of a commit older than the floor is refused" test "$release_status" -ne 0
check "the refusal names the floor commit" grep -qF "older than $floor_sha" <<<"$release_err"
check "a refused release pushes no branch" same "$(sync_branch "$new_sha")" ""
guard_err="$("$SCRIPT_DIR/sync-guard.sh" infra "$base" "$head" someone 2>&1)" && guard_status=0 || guard_status=$?
check "a sync PR for a commit older than the floor fails the guard" test "$guard_status" -ne 0
check "the guard's refusal names the floor commit" grep -qF "older than $floor_sha" <<<"$guard_err"

release_sha "$floor_sha" 2>/dev/null
check "the floor commit releases" test -n "$(sync_branch "$floor_sha")"
check "the floor commit's sync PR passes the guard" guard "$(sync_branch "$floor_sha")"

desc_sha="$(mk_commit "$src" "$(mk_tree "$src" "100644|$GUARD_YML|guard v2" "100644|README.md|readme v3" "100755|scripts/run.sh|#!/bin/sh" "160000|mixer|$GITLINK" "100644|$PIN|source pin")" "v3" "$floor_sha")"
git -C "$src" update-ref refs/heads/main "$desc_sha"
release_sha "$desc_sha" 2>/dev/null
check "a descendant of the floor releases" test -n "$(sync_branch "$desc_sha")"
check "a descendant's sync PR passes the guard" guard "$(sync_branch "$desc_sha")"
check "the floor commit still passes the guard once the branch has moved on" \
    guard "$(sync_branch "$floor_sha")"

# sync_check_floor on its own. The newest commit touches only an
# infra-only control path, so it moves infra's floor and not docs'.
floor_repo="$ROOT/floor"
git init --quiet --bare "$floor_repo"
guard_only="$(mk_commit "$floor_repo" "$(mk_tree "$floor_repo" "100644|$GUARD_YML|guard v1")" "guard")"
lib_change="$(mk_commit "$floor_repo" "$(mk_tree "$floor_repo" "100644|$GUARD_YML|guard v1" "100644|scripts/sync-lib.sh|lib v2")" "lib" "$guard_only")"
git -C "$floor_repo" update-ref refs/source/main "$lib_change"
# shellcheck source=scripts/sync-lib.sh
floor_check() { (cd "$1" && . "$SCRIPT_DIR/sync-lib.sh" && sync_lookup_target "$2" && sync_check_floor "$3") 2>/dev/null; }
check "an infra-only control path moves infra's floor" fails floor_check "$floor_repo" infra "$guard_only"
check "infra's floor is the commit that touched the infra-only path" floor_check "$floor_repo" infra "$lib_change"
check "an infra-only control path leaves docs' floor where it was" floor_check "$floor_repo" docs "$guard_only"

shallow_repo="$ROOT/floor-shallow"
git init --quiet --bare "$shallow_repo"
git -C "$shallow_repo" fetch --quiet --depth 1 "file://$floor_repo" "$lib_change"
git -C "$shallow_repo" update-ref refs/source/main "$lib_change"
check "a shallow source history is refused" fails floor_check "$shallow_repo" infra "$lib_change"

[ -z "${SHOW_GUARD_LOG:-}" ] || cat "$ROOT/guard.log"
total=$((passed + failed))
echo "$passed of $total checks passed."
[ "$total" -gt 0 ] && [ "$failed" -eq 0 ]
