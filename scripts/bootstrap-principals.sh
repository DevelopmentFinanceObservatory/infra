#!/usr/bin/env bash
#
# Create or change a stack's hand-made principals secret.
#
# A stack that grants or notifies people (foundation's applier impersonators,
# ingestion operators and budget alert recipients, the apis stack's invokers,
# the ai stack's token readers, the telemetry stack's reporting readers and
# alert recipients) reads their addresses from a Secret Manager secret, so no
# address sits in this public repository or in a plan log. The secret is an
# object of objects of strings, each inner object keyed by labels that name
# resources in Terraform state and plan output, for example
#   {"readers": {"team": "group:readers@example.org"},
#    "alerts": {"team": "alerts@example.org"}}
#
# The stack in the secret name picks its schema from
# infra/modules/principals-secret/schemas.json, which also holds the label
# and value patterns. infra/modules/principals-secret/README.md states the
# rules; the script refuses content that breaks one before it writes, then
# writes jq's compact, key-sorted form of the one object it checked, so the
# stack reads exactly what passed.
#
# Create a secret from a local file:
#   bootstrap-principals.sh PROJECT SECRET_NAME JSON_FILE
# The script validates the file, creates the secret, grants the
# dfo-infra-planner service account secretAccessor on it, and adds the
# canonical form as the first version. It refuses a secret that already has an
# enabled version. A secret left without a version by a failed run takes the
# same command again: the create and the grant are skipped or repeated
# harmlessly. The foundation stack makes the same grant (principals_planner),
# but the stack's first plan can run before foundation applies.
#
# Change an existing secret:
#   bootstrap-principals.sh edit PROJECT SECRET_NAME
# The script reads the latest enabled version, opens ${EDITOR:-vi} on a copy in
# a private temporary directory, validates the result, and adds it as the next
# version. The directory and everything the editor leaves in it are removed on
# every exit. A copy left unchanged writes nothing. A refused copy is discarded.
#
# Each version replaces the whole secret, so a write built from an older
# version would drop the entries a newer one added. Just before it adds the
# version, the script reads the latest enabled version again and refuses to
# write when it is not the one it started from. AddSecretVersion takes no
# etag, so the check and the write are two calls and a concurrent writer can
# only interleave within that gap.
set -euo pipefail

usage() {
  echo "usage: $(basename "$0") PROJECT SECRET_NAME JSON_FILE" >&2
  echo "       $(basename "$0") edit PROJECT SECRET_NAME" >&2
  exit 2
}

mode=create
if [ "${1:-}" = "edit" ]; then
  mode=edit
  shift
  [ "$#" -eq 2 ] || usage
else
  [ "$#" -eq 3 ] || usage
  json_file=$3
fi

project=$1
secret_name=$2

planner="serviceAccount:dfo-infra-planner@${project}.iam.gserviceaccount.com"

for cmd in gcloud jq; do
  command -v "$cmd" >/dev/null || { echo "error: $cmd not found on PATH" >&2; exit 1; }
done

if [ "$mode" = create ]; then
  [ -f "$json_file" ] || { echo "error: $json_file is not a file" >&2; exit 1; }
fi

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

# One private directory holds every file the script and the editor touch. It
# goes on any exit, including an interrupt.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
canonical="$work/canonical.json"

# validate <file> <label>: refuses, naming <label>, content that breaks a rule;
# otherwise leaves jq's compact, key-sorted form of the one object in $canonical.
validate() {
  local file=$1 label=$2 docs file_leaves parsed_leaves problems

  docs=$(jq -cs . "$file") || { echo "error: $label is not valid JSON" >&2; exit 1; }
  jq -e 'length == 1 and (.[0] | type) == "object"' <<<"$docs" >/dev/null ||
    { echo "error: $label must hold exactly one JSON object" >&2; exit 1; }

  # jq keeps the last of a repeated key, so a repeat shows as a leaf in the
  # file's event stream that the parsed object no longer has.
  file_leaves=$(jq -cn --stream '[inputs | select(length == 2)] | length' "$file")
  parsed_leaves=$(jq -c '[.[0] | tostream | select(length == 2)] | length' <<<"$docs")
  [ "$file_leaves" = "$parsed_leaves" ] ||
    { echo "error: $label repeats a key" >&2; exit 1; }

  jq -cjS '.[0]' <<<"$docs" >"$canonical"

  # The messages name keys only, since a bad label may be an address.
  problems=$(jq -r --argjson schema "$schema" --argjson patterns "$(jq -c . "$schemas")" '
    . as $doc
    | (keys[] as $key | select($schema | has($key) | not) | "unexpected top-level key \($key)"),
      ($schema | to_entries[] | .key as $k | .value as $rule | $patterns.forms[$rule.form] as $form
        | if ($doc | has($k) | not) then "missing top-level key \($k)"
          elif ($doc[$k] | type) != "object" then "\($k) must be an object"
          else $doc[$k] as $obj
            | (if ($obj | length) < $rule.min then "\($k) must hold at least \($rule.min) entry" else empty end),
              (if any($obj | keys[]; test($patterns.label) | not) then "\($k) has a label outside lower-case letters, digits, hyphens and underscores" else empty end),
              (if any($obj[]; (type != "string") or (test($form.pattern) | not)) then "each \($k) value must be \($form.says)" else empty end),
              (if any($obj[]; (type == "string") and (length < $patterns.min_length or (sub($patterns.prefix; "") | length) < $patterns.min_length)) then "each \($k) value and its address must be at least \($patterns.min_length) characters, so CI can mask them" else empty end),
              (if ([$obj[]] | length) != ([$obj[]] | unique | length) then "\($k) holds the same value under two labels" else empty end)
          end)
  ' "$canonical")
  if [ -n "$problems" ]; then
    printf 'error: %s does not match the %s schema:\n' "$label" "$secret_name" >&2
    printf '  %s\n' "${problems//$'\n'/$'\n  '}" >&2
    exit 1
  fi
}

# read_latest: sets $latest to the number of the secret's latest enabled
# version, empty when it has none. Returns 1 when the secret does not exist.
# Any other failure shows gcloud's error and exits.
read_latest() {
  local err="$work/versions-list.err"
  if latest=$(gcloud secrets versions list "$secret_name" --project="$project" \
    --filter="state:ENABLED" --sort-by="~createTime" --limit=1 --format="value(name.basename())" 2>"$err"); then
    return 0
  fi
  if grep -q NOT_FOUND "$err"; then
    return 1
  fi
  cat "$err" >&2
  echo "error: could not list the versions of $secret_name in $project" >&2
  exit 1
}

started_from=""
if [ "$mode" = create ]; then
  # Validate before any gcloud call, so a malformed file never becomes the
  # latest version the stack reads.
  validate "$json_file" "$json_file"
  if read_latest; then
    [ -z "$latest" ] ||
      { echo "error: $secret_name already has version $latest in $project; change it with: $(basename "$0") edit $project $secret_name" >&2; exit 1; }
  else
    gcloud secrets create "$secret_name" --project="$project" --replication-policy=automatic
  fi
else
  read_latest ||
    { echo "error: $secret_name does not exist in $project; create it with: $(basename "$0") $project $secret_name JSON_FILE" >&2; exit 1; }
  [ -n "$latest" ] ||
    { echo "error: $secret_name has no enabled version in $project; write one with: $(basename "$0") $project $secret_name JSON_FILE" >&2; exit 1; }
  started_from=$latest

  gcloud secrets versions access "$started_from" --secret="$secret_name" --project="$project" >"$work/current.json" ||
    { echo "error: could not read version $started_from of $secret_name in $project" >&2; exit 1; }

  # Pretty-print for the editor; content that is not JSON opens as stored.
  edited="$work/principals.json"
  jq -S . "$work/current.json" >"$edited" 2>/dev/null || cp "$work/current.json" "$edited"
  cp "$edited" "$work/before.json"

  read -ra editor <<<"${EDITOR:-vi}"
  "${editor[@]}" "$edited" || { echo "error: the editor exited with an error; nothing was written" >&2; exit 1; }

  if cmp -s "$work/before.json" "$edited"; then
    echo "no change to ${secret_name} version ${started_from}; nothing written"
    exit 0
  fi
  validate "$edited" "the edited file"
fi

gcloud secrets add-iam-policy-binding "$secret_name" --project="$project" \
  --member="$planner" --role="roles/secretmanager.secretAccessor" >/dev/null

# The check runs immediately before the write.
read_latest || { echo "error: $secret_name no longer exists in $project" >&2; exit 1; }
if [ "$latest" != "$started_from" ]; then
  if [ -z "$started_from" ]; then
    echo "error: $secret_name now has version $latest; change it with: $(basename "$0") edit $project $secret_name" >&2
  else
    echo "error: the latest version of $secret_name is $latest, not $started_from; run edit again to start from it" >&2
  fi
  exit 1
fi

gcloud secrets versions add "$secret_name" --project="$project" --data-file="$canonical"

echo "${secret_name} in ${project} has a new latest version in canonical form, readable by ${planner}"
