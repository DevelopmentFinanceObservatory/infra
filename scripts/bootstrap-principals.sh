#!/usr/bin/env bash
#
# Write a stack's hand-made principals secret from a local JSON file.
#
# A stack that grants or notifies people (foundation's applier impersonators,
# ingestion operators and budget alert recipients, the ai stack's token
# readers, the telemetry stack's reporting readers and alert recipients) reads
# their addresses from a Secret Manager secret, so no address sits in this
# public repository or in a plan log. The file is an object of objects of
# strings, each inner object keyed by labels that name resources in Terraform
# state and plan output, for example
#   {"readers": {"team": "group:readers@example.org"},
#    "alerts": {"team": "alerts@example.org"}}
#
# The stack in the secret name picks its schema from
# infra/modules/principals-secret/schemas.json, which also holds the label
# and value patterns. infra/modules/principals-secret/README.md states the
# rules; the script refuses a file that breaks one before any gcloud call,
# then writes jq's compact, key-sorted form of the one object it checked, so
# the stack reads exactly what passed.
#
# This creates the secret when it is absent, adds that canonical form as a new
# version, and grants the dfo-infra-planner service account secretAccessor on
# it. The foundation stack makes the same grant (principals_planner), but the
# stack's first plan can run before foundation applies. Safe to rerun; each
# run adds a version, and the stack reads the latest.
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

# The stack's schema, the label pattern, each form's pattern, the type prefix
# pattern and min_length come from the file infra/modules/principals-secret
# reads at plan, so both sides apply the same rules. The secret is <namespace>-<stack>-principals.
schemas="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/infra/modules/principals-secret/schemas.json"
stack=$(sed -nE 's/^.+-([a-z0-9]+)-principals$/\1/p' <<<"$secret_name")
schema=$(jq -ce --arg stack "$stack" '.stacks[$stack] // empty' "$schemas") || {
  echo "error: $secret_name names no stack in $schemas ($(jq -r '.stacks | keys | join(", ")' "$schemas")), so it has no schema" >&2
  exit 1
}

docs=$(jq -cs . "$json_file") || { echo "error: $json_file is not valid JSON" >&2; exit 1; }
jq -e 'length == 1 and (.[0] | type) == "object"' <<<"$docs" >/dev/null ||
  { echo "error: $json_file must hold exactly one JSON object" >&2; exit 1; }

# jq keeps the last of a repeated key, so a repeat shows as a leaf in the
# file's event stream that the parsed object no longer has.
file_leaves=$(jq -cn --stream '[inputs | select(length == 2)] | length' "$json_file")
parsed_leaves=$(jq -c '[.[0] | tostream | select(length == 2)] | length' <<<"$docs")
[ "$file_leaves" = "$parsed_leaves" ] ||
  { echo "error: $json_file repeats a key" >&2; exit 1; }

canonical=$(mktemp)
trap 'rm -f "$canonical"' EXIT
jq -cjS '.[0]' <<<"$docs" >"$canonical"

# Validate before anything is written, so a malformed file never becomes the
# latest version the stack reads. The messages name keys only, never a value
# or a label, since a bad label may be an address.
problems=$(jq -r --argjson schema "$schema" --argjson patterns "$(jq -c '{label, forms, prefix, min_length}' "$schemas")" '
  {
    member: "group:, user: or serviceAccount: before an address, or domain: before a domain, in lower-case ASCII",
    email: "a bare email address in lower-case ASCII"
  } as $says
  | . as $doc
  | (keys[] as $key | select($schema | has($key) | not) | "unexpected top-level key \($key)"),
    ($schema | to_entries[] | .key as $k | .value as $rule | $patterns.forms[$rule.form] as $form
      | if ($doc | has($k) | not) then "missing top-level key \($k)"
        elif ($doc[$k] | type) != "object" then "\($k) must be an object"
        else $doc[$k] as $obj
          | (if ($obj | length) < $rule.min then "\($k) must hold at least \($rule.min) entry" else empty end),
            (if any($obj | keys[]; test($patterns.label) | not) then "\($k) has a label outside lower-case letters, digits, hyphens and underscores" else empty end),
            (if any($obj[]; (type != "string") or (test($form) | not)) then "each \($k) value must be \($says[$rule.form])" else empty end),
            (if any($obj[]; (type == "string") and (length < $patterns.min_length or (sub($patterns.prefix; "") | length) < $patterns.min_length)) then "each \($k) value and its address must be at least \($patterns.min_length) characters, so CI can mask them" else empty end),
            (if ([$obj[]] | length) != ([$obj[]] | unique | length) then "\($k) holds the same value under two labels" else empty end)
        end)
' "$canonical")
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

gcloud secrets versions add "$secret_name" --project="$project" --data-file="$canonical"

gcloud secrets add-iam-policy-binding "$secret_name" --project="$project" \
  --member="$planner" --role="roles/secretmanager.secretAccessor" >/dev/null

echo "${secret_name} in ${project} holds the canonical form of ${json_file} as its latest version, readable by ${planner}"
