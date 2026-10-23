#!/usr/bin/env bash
#
# Write a stack's hand-made principals secret from a local JSON file.
#
# A stack that grants or notifies people (foundation's applier impersonators
# and ingestion operators, the telemetry stack's reporting readers and alert
# recipients) reads their addresses from a Secret Manager
# secret, so no address sits in this public repository or in a plan log. The
# file is an object of objects of strings, each inner object keyed by labels
# that name resources in Terraform state and plan output, for example
#   {"readers": {"team": "group:readers@example.org"},
#    "alerts": {"team": "alerts@example.org"}}
# A label holds only lower-case letters, digits, hyphens and underscores, so
# an address cannot end up as one. An inner object may be empty, as when an
# environment has no members of that kind, but the file may not be {}.
#
# This creates the secret when it is absent, adds the file as a new version,
# and grants the dfo-infra-planner service account secretAccessor on it. The
# foundation stack makes the same grant (principals_planner), but the stack's
# first plan can run before foundation applies. Safe to rerun; each run adds
# a version, and the stack reads the latest.
#
# Usage: bootstrap-principals.sh PROJECT SECRET_NAME JSON_FILE
#   e.g. bootstrap-principals.sh prod-fin-observatory dfo-prod-telemetry-principals principals.json
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $(basename "$0") PROJECT SECRET_NAME JSON_FILE" >&2
  exit 2
fi

project=$1
secret_name=$2
json_file=$3

planner="serviceAccount:dfo-infra-planner@${project}.iam.gserviceaccount.com"

for cmd in gcloud jq; do
  command -v "$cmd" >/dev/null || { echo "error: $cmd not found on PATH" >&2; exit 1; }
done

[ -f "$json_file" ] || { echo "error: $json_file is not a file" >&2; exit 1; }

# Validate before anything is written, so a malformed file never becomes the
# latest version the stack reads.
if ! jq -e '
    type == "object" and length > 0
    and all(.[]; type == "object"
      and all(keys[]; test("^[a-z0-9_-]+$"))
      and all(.[]; type == "string" and length > 0))
  ' "$json_file" >/dev/null; then
  echo "error: $json_file must be a JSON object of objects of non-empty strings, keyed by labels of lower-case letters, digits, hyphens and underscores" >&2
  exit 1
fi

if gcloud secrets describe "$secret_name" --project="$project" >/dev/null 2>&1; then
  echo "secret ${secret_name} exists in ${project}"
else
  gcloud secrets create "$secret_name" --project="$project" --replication-policy=automatic
fi

gcloud secrets versions add "$secret_name" --project="$project" --data-file="$json_file"

gcloud secrets add-iam-policy-binding "$secret_name" --project="$project" \
  --member="$planner" --role="roles/secretmanager.secretAccessor" >/dev/null

echo "${secret_name} in ${project} holds ${json_file} as its latest version, readable by ${planner}"
