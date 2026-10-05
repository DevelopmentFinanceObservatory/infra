#!/usr/bin/env bash
# Validate the shape of a dcp image-pin PR diff, for
# .github/workflows/approve-image-pin.yml.
#
# Checks:
#   (a) the diff between base and head touches exactly one file:
#       infra/dfo-dev/dcp/image.auto.tfvars
#   (b) within that file, exactly one line is removed and one added, and
#       both match the datacommons_services_image assignment
#   (c) the new value matches the pin's exact shape: registry, project, AR
#       repo, image name, and a sha256 digest (64 lowercase hex) — never a
#       tag
#
# Whether the digest resolves in Artifact Registry is checked separately,
# inline in the workflow after it authenticates to GCP.
#
# On success, prints the new pinned image value on stdout and exits 0. On
# failure, prints one reason to stderr and exits non-zero.
#
# Usage: check-image-pin-diff.sh <base-sha> <head-sha>
#   Run from the repository root, with both commits present locally (a
#   shallow checkout won't have base-sha; the workflow fetches full history).
# Exit: 0  = pin-only change, value printed on stdout
#       10 = diff touches more than image.auto.tfvars
#       11 = image.auto.tfvars diff is not a single-line pin change
#       12 = new value doesn't match the pin shape
#       other = usage/git error
set -euo pipefail

PIN_FILE="infra/dfo-dev/dcp/image.auto.tfvars"
PIN_KEY="datacommons_services_image"
PIN_VALUE_RE='^northamerica-northeast1-docker\.pkg\.dev/dev-fin-observatory/datacommons/dfo-services-image@sha256:[0-9a-f]{64}$'

if [ "$#" -ne 2 ]; then
    echo "usage: $(basename "$0") <base-sha> <head-sha>" >&2
    exit 2
fi

base="$1"
head="$2"

# Triple-dot: diff head against the merge base of base and head, the same
# comparison GitHub shows as "the PR diff". Plain base..head would also pick
# up commits landed on base after the branch point.
changed_files="$(git diff --name-only "$base...$head")"
if [ "$changed_files" != "$PIN_FILE" ]; then
    echo "Diff touches more than just $PIN_FILE:" >&2
    printf '%s\n' "$changed_files" | sed 's/^/  /' >&2
    exit 10
fi

file_diff="$(git diff "$base...$head" -- "$PIN_FILE")"
# Filter out the +++ b/... / --- a/... file headers explicitly, rather than
# requiring a second +/- character after the marker: that shortcut also
# swallows a genuinely empty added or removed line, which would let a pin
# bump plus a blank-line change pass as a single-line diff.
added="$(printf '%s\n' "$file_diff" | grep -E '^\+' | grep -vE '^\+\+\+' || true)"
removed="$(printf '%s\n' "$file_diff" | grep -E '^-' | grep -vE '^---' || true)"

added_count="$(printf '%s\n' "$added" | grep -c . || true)"
removed_count="$(printf '%s\n' "$removed" | grep -c . || true)"

if [ "$added_count" -ne 1 ] || [ "$removed_count" -ne 1 ]; then
    echo "$PIN_FILE diff is not a single-line change (added $added_count, removed $removed_count lines) — expected exactly one line replaced." >&2
    exit 11
fi

added_line="${added#+}"
removed_line="${removed#-}"

assignment_re="^${PIN_KEY}[[:space:]]*=[[:space:]]*\"(.*)\"\$"
if ! [[ "$removed_line" =~ $assignment_re ]]; then
    echo "The removed line in $PIN_FILE is not the $PIN_KEY assignment: $removed_line" >&2
    exit 11
fi
if ! [[ "$added_line" =~ $assignment_re ]]; then
    echo "The added line in $PIN_FILE is not the $PIN_KEY assignment: $added_line" >&2
    exit 11
fi
new_value="${BASH_REMATCH[1]}"

if ! [[ "$new_value" =~ $PIN_VALUE_RE ]]; then
    echo "New $PIN_KEY value doesn't match the expected pin shape: $new_value" >&2
    exit 12
fi

printf '%s\n' "$new_value"
