#!/usr/bin/env bash
#
# Attach GEMINI_API_KEY to a Cloud Run service, sourced from Secret Manager.
#
# Called from infra/stacks/dcp/dfo.tf after the Data Commons stack module
# deploys the service — the module builds that service's secret env vars from a
# hard-coded list and takes no input for adding more, so the key has to go on
# afterwards. Safe to run by hand with the same arguments; it is idempotent.
#
# Talks to the Cloud Run Admin v2 API directly rather than shelling out to
# `gcloud run services update`. gcloud validates every entry in the service's
# existing run.googleapis.com/secrets annotation against a pattern requiring a
# NUMERIC project ("^projects/[0-9]{1,19}/secrets/..."), while Terraform writes
# those paths with the project ID. gcloud therefore rejects a service Terraform
# manages, with "Invalid secret path ... in annotation", before it does any
# work. The v2 API applies no such constraint.
#
# Usage: set-search-api-gemini-key.sh PROJECT REGION SERVICE SECRET_NAME
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: $(basename "$0") PROJECT REGION SERVICE SECRET_NAME" >&2
  exit 2
fi

project=$1
region=$2
service=$3
secret_name=$4

env_var="GEMINI_API_KEY"
secret_path="projects/${project}/secrets/${secret_name}"
api="https://run.googleapis.com/v2/projects/${project}/locations/${region}/services/${service}"

for cmd in curl jq gcloud; do
  command -v "$cmd" >/dev/null || { echo "error: $cmd not found on PATH" >&2; exit 1; }
done

token=$(gcloud auth print-access-token)
auth="Authorization: Bearer ${token}"

# Read-modify-write, so it has to tolerate a concurrent writer — the ingestion
# workflow also updates this service. The etag makes a racing PATCH fail with
# 409/412 instead of silently clobbering the other write; retry re-reads.
for attempt in 1 2 3; do
  service_json=$(curl -sS -f -H "$auth" "$api")

  # Replace any existing entry for this var rather than appending a duplicate,
  # and send the whole template back: updateMask=template swaps the template
  # wholesale, so anything dropped here would be dropped on the service.
  body=$(printf '%s' "$service_json" | jq -c \
    --arg name "$env_var" \
    --arg secret "$secret_path" '
      {
        etag: .etag,
        template: (
          .template
          | del(.revision)
          | .containers[0].env = (
              ((.containers[0].env // []) | map(select(.name != $name)))
              + [{
                  name: $name,
                  valueSource: { secretKeyRef: { secret: $secret, version: "latest" } }
                }]
            )
        )
      }')

  response=$(mktemp)
  code=$(curl -sS -X PATCH "${api}?updateMask=template" \
    -H "$auth" -H "Content-Type: application/json" \
    -d "$body" -o "$response" -w '%{http_code}')

  if [ "$code" = "200" ]; then
    operation=$(jq -r '.name // empty' "$response")
    rm -f "$response"
    break
  fi

  if [ "$code" = "409" ] || [ "$code" = "412" ]; then
    echo "warning: service changed under us (HTTP $code), retrying (attempt ${attempt}/3)" >&2
    cat "$response" >&2
    rm -f "$response"
    [ "$attempt" -eq 3 ] && { echo "error: giving up after 3 conflicting attempts" >&2; exit 1; }
    sleep $((attempt * 2))
    continue
  fi

  echo "error: PATCH failed with HTTP $code" >&2
  cat "$response" >&2
  rm -f "$response"
  exit 1
done

# Wait for the rollout. Returning before the revision is serving would report
# success while the service still runs the revision without the key, or while
# a revision that cannot read the secret is failing to start.
if [ -n "${operation:-}" ]; then
  for _ in $(seq 1 60); do
    op_json=$(curl -sS -f -H "$auth" "https://run.googleapis.com/v2/${operation}")
    if [ "$(printf '%s' "$op_json" | jq -r '.done // false')" = "true" ]; then
      if printf '%s' "$op_json" | jq -e '.error' >/dev/null 2>&1; then
        echo "error: rollout failed" >&2
        printf '%s' "$op_json" | jq '.error' >&2
        exit 1
      fi
      break
    fi
    sleep 5
  done
fi

# Confirm the key is actually on the service, so a silent no-op can't pass.
if ! curl -sS -f -H "$auth" "$api" \
  | jq -e --arg name "$env_var" \
      '.template.containers[0].env | map(select(.name == $name)) | length > 0' >/dev/null; then
  echo "error: ${env_var} is not on ${service} after the update" >&2
  exit 1
fi

echo "${env_var} set on ${service} from ${secret_path}"
