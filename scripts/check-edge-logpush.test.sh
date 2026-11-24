#!/usr/bin/env bash
# Scenario tests for check-edge-logpush.sh against a stub `gcloud`, so nothing
# reaches GCS. The stub serves a bucket from a directory tree: `storage ls`
# lists a prefix or expands a glob, and `storage cat` prints files. It logs
# its arguments, and exits 1 with a permission error when STUB_DENY is set.
# Nothing runs it automatically; run it by hand after touching the script:
#   scripts/check-edge-logpush.test.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-edge-logpush.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin"
export STUB_LOG="$WORK/calls.log" STUB_GCS="$WORK/gcs"

cat >"$WORK/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "gcloud $*" >>"$STUB_LOG"
[ -z "${STUB_DENY:-}" ] || { echo "ERROR: (gcloud.storage.ls) [user] does not have storage.objects.list access" >&2; exit 1; }
[ "$1" = storage ] || exit 3
verb="$2"
shift 2
case "$verb" in
ls)
    url="$1" path="$STUB_GCS/${1#gs://}"
    found=0
    if [[ "$url" == */ ]]; then
        for entry in "$path"*; do
            [ -e "$entry" ] || continue
            found=1
            if [ -d "$entry" ]; then echo "$url$(basename "$entry")/"; else echo "$url$(basename "$entry")"; fi
        done
    else
        for entry in $path; do
            [ -f "$entry" ] || continue
            found=1
            echo "gs://${entry#"$STUB_GCS"/}"
        done
    fi
    [ "$found" = 1 ] || { echo "ERROR: (gcloud.storage.ls) One or more URLs matched no objects." >&2; exit 1; }
    ;;
cat)
    for url in "$@"; do cat "$STUB_GCS/${url#gs://}"; done
    ;;
*) exit 3 ;;
esac
STUB
chmod +x "$WORK/bin/gcloud"
export PATH="$WORK/bin:$PATH"
[ "$(command -v gcloud)" = "$WORK/bin/gcloud" ] || { echo "gcloud stub not first on PATH" >&2; exit 1; }

BUCKET=dfo-prod-edge-logs-test
ROOT="$STUB_GCS/$BUCKET/http_requests"
epoch() { jq -rn --arg t "$1" '$t | fromdateiso8601'; }

failures=0
# run <args...>: runs the script against the tree under $STUB_GCS.
run() {
    : >"$STUB_LOG"
    set +e
    out="$("$SCRIPT" "$@" 2>&1)"
    status=$?
    set -e
    calls="$(cat "$STUB_LOG")"
}
check() {
    if [ "$2" = true ]; then
        echo "ok: $1"
    else
        echo "FAIL: $1"
        printf '%s\n' "$out" | sed 's/^/    out: /'
        failures=$((failures + 1))
    fi
}
is() { [ "$1" = "$2" ] && echo true || echo false; }
says() { [[ "$out" == *"$1"* ]] && echo true || echo false; }

reset() { rm -rf "$STUB_GCS" && mkdir -p "$ROOT"; }
line() { # <timestamp> <path> <cache status> [omit field]
    jq -cn --arg t "$1" --arg p "$2" --arg c "$3" --arg omit "${4:-}" \
        '{EdgeStartTimestamp: $t, RayID: "8f1a", ClientRequestMethod: "GET", ClientRequestHost: "developmentfinance.org",
          ClientRequestPath: $p, ClientIP: "192.0.2.1", CacheCacheStatus: $c, EdgeResponseBytes: 10,
          RequestHeaders: {origin: "https://developmentfinance.org"}} | del(.[$omit])'
}
batch() { # <day> <name> [--plain]; lines on stdin, gzipped unless --plain
    mkdir -p "$ROOT/$1"
    if [ "${3:-}" = --plain ]; then cat >"$ROOT/$1/$2"; else gzip -c >"$ROOT/$1/$2"; fi
}

# 1. Lines in the last hour on the dataset paths are counted by cache status.
reset
NOW="$(epoch 2026-11-19T12:00:00Z)"
{
    line 2026-11-19T11:30:01Z /api/datasets/spec_a/cv_1/files/sha256:aa hit
    line 2026-11-19T11:30:02Z /api/datasets/spec_a/cv_1/files/sha256:aa hit
    line 2026-11-19T11:30:03Z /api/v1/datasets/spec_a/cv_1 miss
    line 2026-11-19T11:30:04Z /api/search/resolve dynamic
    line 2026-11-19T10:30:00Z /api/datasets/spec_a/cv_1 hit
} | batch 20261119 20261119T113000Z_20261119T113100Z_aa11.log.gz
line 2026-11-19T11:59:00Z /api/datasets/spec_b/cv_2 hit | batch 20261119 20261119T105800Z_20261119T105900Z_bb22.log.gz
echo token | batch 20261101 ownership-challenge-abc.txt --plain
CHECK_EDGE_LOGPUSH_NOW="$NOW" run "$BUCKET"
check "lines in the last hour exit 0" "$(is "$status" 0)"
check "only the batch ending in the last hour is read" "$(says "batches ending in the last hour: 1")"
check "the count leaves out other paths and older lines" "$(says "dataset-read lines in the last hour: 3")"
check "hits are counted" "$(says $'hit\t2')"
check "misses are counted" "$(says $'miss\t1')"
check "the challenge file in an old day is not stale" "$(is "$([[ "$out" != *"older than four days"* ]] && echo y)" y)"
check "it only lists and reads" "$(is "$(grep -cvE '^gcloud storage (ls|cat) ' <<<"$calls" || true)" 0)"

# 2. A batch GCS decompressed in transit reads the same.
reset
line 2026-11-19T11:30:01Z /api/datasets/spec_a/cv_1 hit | batch 20261119 20261119T113000Z_20261119T113100Z_cc33.log.gz --plain
CHECK_EDGE_LOGPUSH_NOW="$NOW" run "$BUCKET"
check "a plain batch exits 0" "$(is "$status" 0)"
check "a plain batch is counted" "$(says "dataset-read lines in the last hour: 1")"

# 3. The last hour spans midnight, so the previous day is read too.
reset
line 2026-11-18T23:50:00Z /api/v1/datasets/spec_a/cv_1 revalidated | batch 20261118 20261118T234900Z_20261118T235000Z_dd44.log.gz
CHECK_EDGE_LOGPUSH_NOW="$(epoch 2026-11-19T00:20:00Z)" run "$BUCKET"
check "a run after midnight exits 0" "$(is "$status" 0)"
check "the previous day's batch is counted" "$(says $'revalidated\t1')"

# 4. No lines in the last hour exits 1.
reset
line 2026-11-19T09:00:00Z /api/datasets/spec_a/cv_1 hit | batch 20261119 20261119T085900Z_20261119T090000Z_ee55.log.gz
CHECK_EDGE_LOGPUSH_NOW="$NOW" run "$BUCKET"
check "no recent lines exits 1" "$(is "$status" 1)"
check "no recent lines is named" "$(says "no dataset-read lines in the last hour")"
reset
CHECK_EDGE_LOGPUSH_NOW="$NOW" run "$BUCKET"
check "an empty bucket exits 1" "$(is "$status" 1)"

# 5. A line without ClientIP or CacheCacheStatus exits 1.
for field in ClientIP CacheCacheStatus; do
    reset
    line 2026-11-19T11:30:01Z /api/datasets/spec_a/cv_1 hit "$field" | batch 20261119 20261119T113000Z_20261119T113100Z_ff66.log.gz
    CHECK_EDGE_LOGPUSH_NOW="$NOW" run "$BUCKET"
    check "a line without $field exits 1" "$(is "$status" 1)"
    check "a line without $field is named" "$(says "1 line(s) lack CacheCacheStatus or ClientIP")"
done

# 6. A batch older than four days exits 1 and is listed. One from four days
# before, which the three-day delete rule may not have reached, is kept.
reset
line 2026-11-19T11:30:01Z /api/datasets/spec_a/cv_1 hit | batch 20261119 20261119T113000Z_20261119T113100Z_aa11.log.gz
line 2026-11-15T11:30:01Z /api/datasets/spec_a/cv_1 hit | batch 20261115 20261115T113000Z_20261115T113100Z_8888.log.gz
line 2026-11-14T11:30:01Z /api/datasets/spec_a/cv_1 hit | batch 20261114 20261114T113000Z_20261114T113100Z_9999.log.gz
CHECK_EDGE_LOGPUSH_NOW="$NOW" run "$BUCKET"
check "a stale batch exits 1" "$(is "$status" 1)"
check "the stale batch is listed" "$(says "20261114/20261114T113000Z_20261114T113100Z_9999.log.gz")"
check "a batch within the delete rule's reach is not listed" "$(is "$([[ "$out" != *"20261115/"* ]] && echo y)" y)"

# 7. A gcloud error exits 1 and is printed.
reset
STUB_DENY=1 CHECK_EDGE_LOGPUSH_NOW="$NOW" run "$BUCKET"
check "a gcloud error exits 1" "$(is "$status" 1)"
check "a gcloud error is printed" "$(says "does not have storage.objects.list access")"

# 8. Usage errors exit 2 and call nothing.
run
check "no arguments exits 2" "$(is "$status" 2)"
run "gs://$BUCKET"
check "a gs:// url exits 2" "$(is "$status" 2)"
run "$BUCKET" extra
check "two arguments exits 2" "$(is "$status" 2)"
CHECK_EDGE_LOGPUSH_NOW=noon run "$BUCKET"
check "a non-numeric time exits 2" "$(is "$status" 2)"
check "usage errors call nothing" "$(is "$calls" "")"

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed."
    exit 1
fi
echo "All checks passed."
