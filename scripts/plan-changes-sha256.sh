#!/usr/bin/env bash
# Prints the SHA-256 of the changes in a saved Terraform plan, so two plans
# of the same stack can be compared without moving the plan file between
# jobs. The hash covers each resource and output change other than no-op:
# its address, its actions, the top-level attributes whose planned value
# differs from the current one (with both values), and which attributes stay
# unknown until apply. Attributes the plan leaves unchanged are out of the
# hash, so a computed value that moves between two plans, such as a Logpush
# job's last_complete, gives the same hash while nothing is to change.
# Run it in the stack's directory after terraform init.
#
# Usage: plan-changes-sha256.sh <plan-file>
# Exit: 0 with the hash on stdout, 1 when terraform show or jq fails, 2 on a
# usage error.
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: plan-changes-sha256.sh <plan-file>" >&2
    exit 2
fi

json="$(terraform show -json "$1")"
changes="$(jq -cS '
    def changed($b; $a):
        if ($b | type) == "object" and ($a | type) == "object" then
            reduce (($b + $a) | keys[]) as $k ({};
                if $b[$k] == $a[$k] then . else .[$k] = {before: $b[$k], after: $a[$k]} end)
        else {before: $b, after: $a} end;
    def entry: {
        actions: .change.actions,
        changed: changed(.change.before; .change.after),
        unknown: .change.after_unknown
    };
    {
        resources: [.resource_changes[]? | select(.change.actions != ["no-op"]) | {address} + entry] | sort_by(.address),
        outputs: [(.output_changes // {}) | to_entries[] | select(.value.actions != ["no-op"]) | {name: .key, actions: .value.actions, changed: changed(.value.before; .value.after)}] | sort_by(.name)
    }' <<<"$json")"

if command -v sha256sum >/dev/null; then
    printf '%s' "$changes" | sha256sum | cut -d' ' -f1
else
    printf '%s' "$changes" | shasum -a 256 | cut -d' ' -f1
fi
