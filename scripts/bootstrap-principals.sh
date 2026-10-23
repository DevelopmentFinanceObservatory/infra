#!/usr/bin/env bash
#
# Write a stack's hand-made principals secret from a local JSON file.
#
# A stack that grants or notifies people (foundation's applier impersonators,
# ingestion operators and budget alert recipients, the ai stack's token readers, the telemetry stack's
# reporting readers and alert recipients) reads their addresses from a Secret
# Manager secret, so no address sits in this public repository or in a plan
# log. The file is an object of objects of strings, each inner object keyed by
# labels that name resources in Terraform state and plan output, for example
#   {"readers": {"team": "group:readers@example.org"},
#    "alerts": {"team": "alerts@example.org"}}
# A label holds only lower-case letters, digits, hyphens and underscores, so
# an address cannot end up as one. The secret name's suffix picks the schema
# below: the exact top-level keys, the form of each value, and which objects
# must be non-empty. No value may appear under two labels of one object, since
# removing either label would revoke both. The rules match the postconditions
# on each stack's principals data source.
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

[[ "$project" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || { echo "error: $project is not a GCP project id" >&2; exit 1; }
[[ "$secret_name" =~ ^[A-Za-z0-9_-]{1,255}$ ]] || { echo "error: $secret_name is not a Secret Manager secret name" >&2; exit 1; }

# Each schema maps a top-level key to the form of its values, "member" (an IAM
# member string) or "email" (a bare address), and the fewest entries it holds.
case "$secret_name" in
*-foundation-principals)
  schema='{"applier_impersonators": {"form": "member", "min": 0}, "ingestion_operators": {"form": "member", "min": 0}, "budget_alerts": {"form": "email", "min": 0}}' ;;
*-ai-principals)
  schema='{"studio_token_readers": {"form": "member", "min": 0}, "mcp_token_readers": {"form": "member", "min": 0}}' ;;
*-telemetry-principals)
  schema='{"readers": {"form": "member", "min": 0}, "alerts": {"form": "email", "min": 1}}' ;;
*)
  echo "error: $secret_name ends in none of -foundation-principals, -ai-principals, -telemetry-principals, so it has no schema" >&2
  exit 1 ;;
esac

# Validate before anything is written, so a malformed file never becomes the
# latest version the stack reads. The messages name keys only, never a value
# or a label, since a bad label may be an address.
problems=$(jq -r --argjson schema "$schema" '
  {
    member: {re: "^(group|user|serviceAccount|domain):[^:]+$", says: "group:, user:, serviceAccount: or domain: followed by an address"},
    email: {re: "^[^@:\\s]+@[^@:\\s]+$", says: "a bare email address, with no member prefix"}
  } as $forms
  | . as $doc
  | if type != "object" then "the file must hold a JSON object"
    else
      (keys[] as $key | select($schema | has($key) | not) | "unexpected top-level key \($key)"),
      ($schema | to_entries[] | .key as $k | .value as $rule | $forms[$rule.form] as $form
        | if ($doc | has($k) | not) then "missing top-level key \($k)"
          elif ($doc[$k] | type) != "object" then "\($k) must be an object"
          else $doc[$k] as $obj
            | (if ($obj | length) < $rule.min then "\($k) must hold at least \($rule.min) entry" else empty end),
              (if any($obj | keys[]; test("^[a-z0-9_-]+$") | not) then "\($k) has a label outside lower-case letters, digits, hyphens and underscores" else empty end),
              (if any($obj[]; (type != "string") or (test($form.re) | not)) then "each \($k) value must be \($form.says)" else empty end),
              (if ([$obj[]] | length) != ([$obj[]] | unique | length) then "\($k) holds the same value under two labels" else empty end)
          end)
    end
' "$json_file") || { echo "error: $json_file is not valid JSON" >&2; exit 1; }
if [ -n "$problems" ]; then
  printf 'error: %s does not match the %s schema:\n' "$json_file" "$secret_name" >&2
  printf '  %s\n' "${problems//$'\n'/$'\n  '}" >&2
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
