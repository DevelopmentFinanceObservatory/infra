#!/usr/bin/env bash
# Scenario tests for mask-principals.sh against a stub `gcloud`, so nothing
# reaches GCP. The stub serves secrets from files in a fixture directory and
# logs every call. Not wired into CI or pre-commit. Run by hand after
# touching the script:
#   scripts/mask-principals.test.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mask-principals.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin" "$WORK/secrets"
export STUB_LOG="$WORK/calls.log" STUB_SECRETS="$WORK/secrets"

# gcloud: `secrets list` prints one file name per line from $STUB_SECRETS,
# or fails when $STUB_FAIL_LIST is set. `secrets versions access latest
# --secret=NAME` prints that file, or fails when NAME is $STUB_FAIL_ACCESS.
cat >"$WORK/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "gcloud $*" >>"$STUB_LOG"
case "$1 $2" in
"secrets list")
    [ -n "${STUB_FAIL_LIST:-}" ] && { echo "ERROR: PERMISSION_DENIED" >&2; exit 1; }
    ls "$STUB_SECRETS"
    ;;
"secrets versions")
    name=""
    for a in "$@"; do case "$a" in --secret=*) name="${a#--secret=}" ;; esac; done
    [ "$name" = "${STUB_FAIL_ACCESS:-}" ] && { echo "ERROR: PERMISSION_DENIED" >&2; exit 1; }
    cat "$STUB_SECRETS/$name"
    ;;
*) echo "stub: unexpected gcloud $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$WORK/bin/gcloud"
export PATH="$WORK/bin:$PATH"
[ "$(command -v gcloud)" = "$WORK/bin/gcloud" ] || { echo "gcloud stub not first on PATH" >&2; exit 1; }

failures=0
OUT_FILE="$WORK/addresses"

# run <args...>: runs the script with a fresh log and output file, leaving
# its status in $status, its output in $out, the file in $file and the log
# in $calls.
run() {
    : >"$STUB_LOG"
    rm -f "$OUT_FILE"
    set +e
    out="$("$SCRIPT" "$@" 2>&1)"
    status=$?
    set -e
    calls="$(cat "$STUB_LOG")"
    file="$(cat "$OUT_FILE" 2>/dev/null || echo "<missing>")"
}

check() {
    local label="$1" ok="$2"
    if [ "$ok" = true ]; then
        echo "ok: $label"
    else
        echo "FAIL: $label"
        printf '%s\n' "$out" | sed 's/^/    out: /'
        printf '%s\n' "$calls" | sed 's/^/    log: /'
        printf '%s\n' "$file" | sed 's/^/    file: /'
        failures=$((failures + 1))
    fi
}

is() { [ "$1" = "$2" ] && echo true || echo false; }
says() { [[ "$out" == *"$1"* ]] && echo true || echo false; }
has() { [[ "$calls" == *"$1"* ]] && echo true || echo false; }
lacks() { [[ "$calls" != *"$1"* ]] && echo true || echo false; }
# Output lines other than ::add-mask:: commands, where a value must not appear.
plain() { printf '%s\n' "$out" | grep -v '^::add-mask::' || true; }

# 1. A project with no principals secrets masks nothing and writes an empty
# file. A secret named `-principal`, singular, is not one.
printf 'not-a-member-list' >"$WORK/secrets/ns-apis-live-refresh-principal"
run example-project "$OUT_FILE"
check "no principals secrets exits 0" "$(is "$status" 0)"
check "no principals secrets writes an empty file" "$(is "$file" "")"
check "no principals secrets prints no mask" "$(is "$(printf '%s\n' "$out" | grep -c '^::add-mask::' || true)" 0)"
check "a -principal secret is not read" "$(lacks 'versions access')"
check "listing names the project" "$(has 'secrets list --project=example-project')"

# 2. Each value is masked whole and without its type prefix, at any depth,
# each lower-cased and URL-encoded from both cases, and the file holds the
# same set once each.
cat >"$WORK/secrets/ns-apis-principals" <<'JSON'
{"invokers": {"devs": "group:devs@example.org", "lead": "Lead.Person@Example.org"}}
JSON
cat >"$WORK/secrets/ns-website-principals" <<'JSON'
{"admins": {"ops": "user:ops@example.org", "devs": "group:devs@example.org"}, "nested": {"a": {"b": "serviceAccount:bot@example.iam.gserviceaccount.com"}}}
JSON
expected="$(printf '%s\n' \
    group:devs@example.org group%3Adevs%40example.org group%3adevs%40example.org \
    devs@example.org devs%40example.org \
    Lead.Person@Example.org lead.person@example.org Lead.Person%40Example.org lead.person%40example.org \
    user:ops@example.org user%3Aops%40example.org user%3aops%40example.org \
    ops@example.org ops%40example.org \
    serviceAccount:bot@example.iam.gserviceaccount.com serviceaccount:bot@example.iam.gserviceaccount.com \
    serviceAccount%3Abot%40example.iam.gserviceaccount.com serviceaccount%3abot%40example.iam.gserviceaccount.com \
    serviceaccount%3Abot%40example.iam.gserviceaccount.com \
    bot@example.iam.gserviceaccount.com bot%40example.iam.gserviceaccount.com | sort -u)"
run example-project "$OUT_FILE"
check "principals secrets exit 0" "$(is "$status" 0)"
check "the file holds every form of every member and address once" "$(is "$file" "$expected")"
check "every file line is masked" "$(is "$(printf '%s\n' "$out" | grep '^::add-mask::' | sed 's/^::add-mask:://')" "$expected")"
check "no value appears outside a mask command" "$(is "$(plain | grep -ci 'example\.org' || true)" 0)"
check "each principals secret is read at latest in the project" "$(has 'secrets versions access latest --secret=ns-apis-principals --project=example-project')"
check "the second principals secret is read" "$(has '--secret=ns-website-principals')"
check "the summary counts values and secrets" "$(says 'Masked 21 principal value(s) from 2 secret(s)')"
check "the file is private" "$(is "$(stat -f '%Lp' "$OUT_FILE" 2>/dev/null || stat -c '%a' "$OUT_FILE")" 600)"

# The URL-encoded form escapes what encodeURIComponent escapes, and keeps
# the !'()* that jq's @uri would also escape.
printf '%s' '{"a": {"b": "user:O'"'"'Neil+(x)@example.org"}}' >"$WORK/secrets/ns-ai-principals"
run example-project "$OUT_FILE"
rm "$WORK/secrets/ns-ai-principals"
check "an address with reserved characters exits 0" "$(is "$status" 0)"
check "it is URL-encoded as encodeURIComponent does" "$(is "$(grep -cx "O'Neil%2B(x)%40example.org" <<<"$file" || true)" 1)"
check "and lower-cased" "$(is "$(grep -cx "user%3ao'neil%2b(x)%40example.org" <<<"$file" || true)" 1)"

# 3. A failed listing fails, and writes no file.
export STUB_FAIL_LIST=1
run example-project "$OUT_FILE"
unset STUB_FAIL_LIST
check "a failed listing exits 1" "$(is "$status" 1)"
check "a failed listing writes no file" "$(is "$file" "<missing>")"

# 4. A secret that cannot be read fails, naming it.
export STUB_FAIL_ACCESS=ns-website-principals
run example-project "$OUT_FILE"
unset STUB_FAIL_ACCESS
check "an unreadable secret exits 1" "$(is "$status" 1)"
check "an unreadable secret is named" "$(says 'ns-website-principals')"
check "an unreadable secret writes no file" "$(is "$file" "<missing>")"
check "an unreadable secret prints no mask" "$(is "$(printf '%s\n' "$out" | grep -c '^::add-mask::' || true)" 0)"

# 5. A secret that is not a JSON object fails without printing its content.
printf '["group:devs@example.org"]' >"$WORK/secrets/ns-apis-principals"
run example-project "$OUT_FILE"
check "a JSON array exits 1" "$(is "$status" 1)"
check "a JSON array is not printed" "$(is "$(plain | grep -c 'example\.org' || true)" 0)"
printf 'group:devs@example.org' >"$WORK/secrets/ns-apis-principals"
run example-project "$OUT_FILE"
check "a non-JSON secret exits 1" "$(is "$status" 1)"
check "a non-JSON secret is not printed" "$(is "$(plain | grep -c 'example\.org' || true)" 0)"

# 6. A value GitHub cannot mask fails without printing it.
printf '{"a": {"b": "abc"}}' >"$WORK/secrets/ns-apis-principals"
run example-project "$OUT_FILE"
check "a 3-character value exits 1" "$(is "$status" 1)"
check "a 3-character value is not printed" "$(is "$(plain | grep -c 'abc' || true)" 0)"
printf '{"a": {"b": "user:abc"}}' >"$WORK/secrets/ns-apis-principals"
run example-project "$OUT_FILE"
check "a 3-character address exits 1" "$(is "$status" 1)"
printf '{"a": {"b": "two@example.org\\nlines@example.org"}}' >"$WORK/secrets/ns-apis-principals"
run example-project "$OUT_FILE"
check "a value spanning lines exits 1" "$(is "$status" 1)"
check "a value spanning lines is not printed" "$(is "$(plain | grep -c 'example\.org' || true)" 0)"

# 7. Arguments.
run example-project
check "a missing out-file exits 1" "$(is "$status" 1)"
check "a missing out-file makes no gcloud call" "$(is "$calls" "")"
run "" "$OUT_FILE"
check "an empty project exits 1" "$(is "$status" 1)"
run --help
check "--help exits 0" "$(is "$status" 0)"
check "--help prints the usage" "$(says 'Usage: scripts/mask-principals.sh <project> <out-file>')"

if [ "$failures" -eq 0 ]; then
    echo "All scenarios passed."
    exit 0
else
    echo "$failures scenario(s) failed."
    exit 1
fi
