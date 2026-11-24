#!/usr/bin/env bash
# Fails when a saved Terraform plan mounts a secret version that is missing,
# disabled or destroyed.
#
# A Cloud Run service or Job that pins a secret env var to a version number
# (API_KEY_TAG_SECRETS and ADMIN_EMAILS in the website stack, set in
# env.auto.tfvars) passes plan whatever state that version is in, since the
# pin is checked only for format. A missing or disabled version then stops the
# apply's revision from starting, and every later image deploy fails with it.
# This reads each pinned version's metadata with
# `gcloud secrets versions describe`, which needs secretmanager.versions.get
# (roles/viewer holds it) and never reads a payload. A Terraform data source
# would write the payload to state, so this is not one.
#
# Only known numeric versions are checked. `latest` and a version the apply
# will create (unknown at plan, as when a generated secret is rotated) are
# skipped. A version of a secret this same plan creates cannot exist yet, so
# version 1 of such a secret passes: the apply writes it before the revision
# that mounts it (see the stack's readiness_dependencies).
#
# The jq path follows the google provider's schema (7.40.0):
# template[] > containers[] > env[] (a set, a JSON array in the plan) >
# value_source[] > secret_key_ref[] {secret, version}, and a Job adds an outer
# template[]. The search below descends to any depth, so both match.
#
# Each REQUIRED_ENV name must turn up as a known numeric pin, or the check
# fails. That keeps it from passing silently if the plan's shape ever stops
# matching the jq path above, or a pin moves back to `latest`.
#
# Usage: check-secret-pins.sh <planfile> <default-project> [REQUIRED_ENV...]
#   run from the stack's terraform dir. <default-project> is used only when a
#   planned resource names no project.
# Exit:  0 = every pinned version is ENABLED and every REQUIRED_ENV is pinned,
#        3 = a version is not ENABLED or a REQUIRED_ENV is not pinned,
#        other = error.
set -euo pipefail

usage="usage: check-secret-pins.sh <planfile> <default-project> [REQUIRED_ENV...]"
plan="${1:?$usage}"
default_project="${2:?$usage}"
shift 2

command -v gcloud >/dev/null || { echo "::error::gcloud not found." >&2; exit 1; }

# Write the JSON to a file first rather than piping, as check-destroys.sh does.
terraform show -json "$plan" >"$plan.pins.json"

# One line per pinned mount: project, secret, version, resource address, env
# name.
pins="$(jq -r --arg project "$default_project" '
  (.resource_changes // [])[]
  | select(.type == "google_cloud_run_v2_service" or .type == "google_cloud_run_v2_job")
  | select(.change.after != null)
  | .address as $addr
  | (.change.after.project // $project) as $proj
  | .change.after
  | ..
  | objects
  | select(has("value_source"))
  | .name as $name
  | .value_source[]?
  | .secret_key_ref[]?
  | select((.secret | type) == "string" and (.version | type) == "string")
  | select(.version | test("^[0-9]+$"))
  | [$proj, .secret, .version, $addr, $name]
  | @tsv
' "$plan.pins.json" | sort -u)"

# Secrets the plan creates, as project<TAB>secret_id.
created="$(jq -r --arg project "$default_project" '
  (.resource_changes // [])[]
  | select(.type == "google_secret_manager_secret")
  | select(.change.actions | index("create"))
  | [(.change.after.project // $project), .change.after.secret_id]
  | @tsv
' "$plan.pins.json")"

bad=0
for required in "$@"; do
  if ! cut -f5 <<<"$pins" | grep -qxF "$required"; then
    echo "::error::No numeric secret pin for $required in this plan. Either the stack no longer pins it or this script no longer reads the plan's shape."
    bad=1
  fi
done

if [ -z "$pins" ]; then
  echo "No pinned secret versions in this plan."
  exit "$((bad ? 3 : 0))"
fi

while IFS=$'\t' read -r project secret version address name; do
  # A secret_key_ref may name a secret in full (projects/<p>/secrets/<s>).
  if [[ "$secret" == projects/*/secrets/* ]]; then
    project="${secret#projects/}"
    project="${project%%/*}"
    secret="${secret##*/}"
  fi
  label="$name: $project/$secret version $version ($address)"
  set +e
  state="$(gcloud secrets versions describe "$version" --secret="$secret" --project="$project" --format='value(state)' 2>"$plan.pins.err" </dev/null)"
  code=$?
  set -e
  if [ "$code" -ne 0 ]; then
    if grep -q "NOT_FOUND" "$plan.pins.err"; then
      if [ "$version" = "1" ] && grep -qxF "$project"$'\t'"$secret" <<<"$created"; then
        echo "ok: $label is created by this plan"
        continue
      fi
      echo "::error::$label does not exist."
      bad=1
      continue
    fi
    cat "$plan.pins.err" >&2
    echo "::error::Could not describe $label (exit $code)."
    exit 1
  fi
  if [ "$state" = "ENABLED" ]; then
    echo "ok: $label is ENABLED"
  else
    echo "::error::$label is ${state:-in no state}, not ENABLED. A revision that mounts it cannot start."
    bad=1
  fi
done <<<"$pins"

if [ "$bad" -ne 0 ]; then
  exit 3
fi
