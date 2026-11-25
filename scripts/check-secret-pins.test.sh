#!/usr/bin/env bash
# Scenario tests for check-secret-pins.sh against stub `terraform` and
# `gcloud`, so nothing reaches GCP. `terraform show -json` prints the fixture
# plan in $STUB_PLAN, and `gcloud secrets versions describe` answers from
# $STUB_STATES. Not wired into CI or pre-commit. Run by hand after touching
# the script:
#   scripts/check-secret-pins.test.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-secret-pins.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin"
export STUB_LOG="$WORK/calls.log" STUB_PLAN="$WORK/plan.json" STUB_STATES="$WORK/states"

cat >"$WORK/bin/terraform" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "show -json" ] || { echo "stub: unexpected terraform $*" >&2; exit 2; }
cat "$STUB_PLAN"
STUB

# gcloud: $STUB_STATES holds lines "project/secret/version STATE". A missing
# line answers NOT_FOUND, and the STATE `DENIED` answers PERMISSION_DENIED.
cat >"$WORK/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "gcloud $*" >>"$STUB_LOG"
[ "$1 $2 $3" = "secrets versions describe" ] || { echo "stub: unexpected gcloud $*" >&2; exit 2; }
version="$4" secret="" project=""
for a in "$@"; do
    case "$a" in --secret=*) secret="${a#--secret=}" ;; --project=*) project="${a#--project=}" ;; esac
done
state="$(awk -v k="$project/$secret/$version" '$1 == k { print $2 }' "$STUB_STATES")"
case "$state" in
"") echo "ERROR: (gcloud.secrets.versions.describe) NOT_FOUND: Secret Version [$version] not found." >&2; exit 1 ;;
DENIED) echo "ERROR: (gcloud.secrets.versions.describe) PERMISSION_DENIED: denied." >&2; exit 1 ;;
*) echo "$state" ;;
esac
STUB
chmod +x "$WORK/bin/terraform" "$WORK/bin/gcloud"
export PATH="$WORK/bin:$PATH"

failures=0

# plan <secret-creates-json> <env-json...>: writes a plan with one service
# in project p whose env holds the given entries, and creates the given
# secrets.
plan() {
    local creates="$1"
    shift
    local env
    env="$(printf '%s\n' "$@" | jq -s '.')"
    jq -n --argjson env "$env" --argjson creates "$creates" '{
      resource_changes: (
        [{
          address: "module.website_service.google_cloud_run_v2_service.this",
          type: "google_cloud_run_v2_service",
          change: { actions: ["update"], after: { project: "p", template: [{ containers: [{ env: $env }] }] } }
        }]
        + [ $creates[] | {
          address: "google_secret_manager_secret.\(.)",
          type: "google_secret_manager_secret",
          change: { actions: ["create"], after: { project: "p", secret_id: . } }
        } ]
      )
    }' >"$STUB_PLAN"
}

# add_version <secret-id>: adds to the fixture plan a create of a version of
# secret <secret-id> in project p, which is already in state.
add_version() {
    jq --arg s "projects/p/secrets/$1" '.resource_changes += [{
      address: "google_secret_manager_secret_version.v",
      type: "google_secret_manager_secret_version",
      change: { actions: ["create"], after: { secret: $s } }
    }]' "$STUB_PLAN" >"$STUB_PLAN.tmp" && mv "$STUB_PLAN.tmp" "$STUB_PLAN"
}

ref() { jq -n --arg n "$1" --arg s "$2" --arg v "$3" '{name: $n, value_source: [{secret_key_ref: [{secret: $s, version: $v}]}]}'; }
unknown() { jq -n --arg n "$1" --arg s "$2" '{name: $n, value_source: [{secret_key_ref: [{secret: $s}]}]}'; }
plain() { jq -n --arg n "$1" '{name: $n, value: "x"}'; }

# run [REQUIRED_ENV...]: runs the script on the fixture plan.
run() {
    : >"$STUB_LOG"
    set +e
    out="$(cd "$WORK" && "$SCRIPT" tfplan fallback "$@" 2>&1)"
    status=$?
    set -e
    calls="$(cat "$STUB_LOG")"
}

check() {
    if [ "$2" = true ]; then
        echo "ok: $1"
    else
        echo "FAIL: $1 (status $status)"
        printf '%s\n' "$out" | sed 's/^/    out: /'
        printf '%s\n' "$calls" | sed 's/^/    log: /'
        failures=$((failures + 1))
    fi
}
is() { [ "$1" = "$2" ] && echo true || echo false; }
says() { [[ "$out" == *"$1"* ]] && echo true || echo false; }
lacks() { [[ "$calls" != *"$1"* ]] && echo true || echo false; }

# 1. Enabled pins pass, and `latest`, unknown versions and plain values are
# not looked up.
printf '%s\n' "p/tag/3 ENABLED" "p/admins/2 ENABLED" >"$STUB_STATES"
plan '[]' "$(ref API_KEY_TAG_SECRETS tag 3)" "$(ref ADMIN_EMAILS admins 2)" \
    "$(ref STUDIO_TOKEN studio latest)" "$(unknown BETTER_AUTH_SECRET auth)" "$(plain TIER)"
run
check "enabled pins exit 0" "$(is "$status" 0)"
check "both pins are reported" "$(says "p/tag version 3")"
check "the admin pin is reported" "$(says "p/admins version 2")"
check "latest is not looked up" "$(lacks "--secret=studio")"
check "an unknown version is not looked up" "$(lacks "--secret=auth")"

# 2. A disabled pin fails with 3 and names the version.
printf '%s\n' "p/tag/3 DISABLED" "p/admins/2 ENABLED" >"$STUB_STATES"
plan '[]' "$(ref API_KEY_TAG_SECRETS tag 3)" "$(ref ADMIN_EMAILS admins 2)"
run
check "a disabled pin exits 3" "$(is "$status" 3)"
check "the disabled pin is named" "$(says "p/tag version 3")"
check "the state is named" "$(says "DISABLED")"

# 3. A destroyed pin fails.
printf '%s\n' "p/tag/3 ENABLED" "p/admins/1 DESTROYED" >"$STUB_STATES"
plan '[]' "$(ref API_KEY_TAG_SECRETS tag 3)" "$(ref ADMIN_EMAILS admins 1)"
run
check "a destroyed pin exits 3" "$(is "$status" 3)"

# 4. A missing version of an existing secret fails.
printf '%s\n' "p/tag/3 ENABLED" >"$STUB_STATES"
plan '[]' "$(ref API_KEY_TAG_SECRETS tag 4)"
run
check "a missing version exits 3" "$(is "$status" 3)"
check "the missing version is named" "$(says "does not exist")"

# 5. Version 1 of a secret this plan creates passes, as on the first apply.
: >"$STUB_STATES"
plan '["tag","admins"]' "$(ref API_KEY_TAG_SECRETS tag 1)" "$(ref ADMIN_EMAILS admins 1)"
run
check "version 1 of a created secret exits 0" "$(is "$status" 0)"
check "it says the plan creates it" "$(says "created by this plan")"

# 6. Any other version of a created secret fails.
plan '["tag"]' "$(ref API_KEY_TAG_SECRETS tag 2)"
run
check "version 2 of a created secret exits 3" "$(is "$status" 3)"

# 6a. Version 1 passes when the plan creates that version of a secret already
# in state, as after a first apply that created the secret and failed before
# its version. Any other version of that secret, and version 1 of another
# secret, still fail.
: >"$STUB_STATES"
plan '[]' "$(ref ADMIN_EMAILS admins 1)"
add_version admins
run ADMIN_EMAILS
check "version 1 of a planned version exits 0" "$(is "$status" 0)"
check "it says the plan creates it" "$(says "created by this plan")"
plan '[]' "$(ref ADMIN_EMAILS admins 2)" "$(ref API_KEY_TAG_SECRETS tag 1)"
add_version admins
run
check "version 2, or another secret's version 1, exits 3" "$(is "$status" 3)"
check "the other secret's version 1 is named" "$(says "p/tag version 1")"
check "version 2 is named" "$(says "p/admins version 2")"

# 7. A lookup that fails for another reason is an error, not a pass.
printf '%s\n' "p/tag/3 DENIED" >"$STUB_STATES"
plan '[]' "$(ref API_KEY_TAG_SECRETS tag 3)"
run
check "a denied lookup exits 1" "$(is "$status" 1)"

# 8. A secret named in full is looked up in its own project.
printf '%s\n' "other/shared/5 ENABLED" >"$STUB_STATES"
plan '[]' "$(ref SHARED projects/other/secrets/shared 5)"
run
check "a full secret name exits 0" "$(is "$status" 0)"
check "it is looked up in its project" "$(says "other/shared version 5")"

# 9. A plan with no pinned mounts passes without a lookup.
plan '[]' "$(plain TIER)"
run
check "no pins exits 0" "$(is "$status" 0)"
check "no pins looks nothing up" "$(is "$calls" "")"

# 10. Required names that are pinned pass, as the workflows call it.
printf '%s\n' "p/tag/3 ENABLED" "p/admins/2 ENABLED" >"$STUB_STATES"
plan '[]' "$(ref API_KEY_TAG_SECRETS tag 3)" "$(ref ADMIN_EMAILS admins 2)"
run API_KEY_TAG_SECRETS ADMIN_EMAILS
check "required pins found exits 0" "$(is "$status" 0)"
check "the env name is reported" "$(says "ADMIN_EMAILS: p/admins version 2")"

# 11. A required name mounted at latest fails closed and is named.
plan '[]' "$(ref API_KEY_TAG_SECRETS tag 3)" "$(ref ADMIN_EMAILS admins latest)"
run API_KEY_TAG_SECRETS ADMIN_EMAILS
check "a required pin at latest exits 3" "$(is "$status" 3)"
check "the missing pin is named" "$(says "No numeric secret pin for ADMIN_EMAILS")"
check "the found pin is not called missing" "$([[ "$out" != *"pin for API_KEY_TAG_SECRETS"* ]] && echo true || echo false)"

# 12. A plan whose shape the jq path does not match finds no pin, and fails
# closed rather than passing.
jq -n '{resource_changes: [{
  address: "module.website_service.google_cloud_run_v2_service.this",
  type: "google_cloud_run_v2_service",
  change: { actions: ["update"], after: { project: "p", template: [{ containers: [{ env: [
    { name: "API_KEY_TAG_SECRETS", secret_key_ref: { secret: "tag", version: "3" } }
  ] }] }] } }
}]}' >"$STUB_PLAN"
run API_KEY_TAG_SECRETS ADMIN_EMAILS
check "an unmatched plan shape exits 3" "$(is "$status" 3)"
check "both missing pins are named" "$(says "pin for API_KEY_TAG_SECRETS")"
check "an unmatched plan shape looks nothing up" "$(is "$calls" "")"

# 13. A plan with no Cloud Run resource at all fails when names are required.
jq -n '{resource_changes: []}' >"$STUB_PLAN"
run ADMIN_EMAILS
check "no service with a required name exits 3" "$(is "$status" 3)"

# 14. A Job's pins, one template deeper, are found.
printf '%s\n' "p/tag/3 ENABLED" >"$STUB_STATES"
jq -n --argjson env "[$(ref API_KEY_TAG_SECRETS tag 3)]" '{resource_changes: [{
  address: "google_cloud_run_v2_job.j",
  type: "google_cloud_run_v2_job",
  change: { actions: ["update"], after: { project: "p", template: [{ template: [{ containers: [{ env: $env }] }] }] } }
}]}' >"$STUB_PLAN"
run API_KEY_TAG_SECRETS
check "a Job pin is found" "$(is "$status" 0)"

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"
