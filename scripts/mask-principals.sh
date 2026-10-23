#!/usr/bin/env bash
# Mask the principal addresses Terraform reads from Secret Manager, so no
# group or person address reaches a GitHub Actions log or a PR comment.
#
# Stacks read IAM members from hand-made secrets named
# `<namespace>-<stack>-principals`, each a JSON object whose string values
# are IAM members such as `group:team@example.org`, or bare addresses.
# Terraform's `sensitive` does not hide them: the Google provider sets each
# `*_iam_member` resource's id to `<resource>/<role>/<member>`, and Terraform
# prints ids in its `Refreshing state... [id=...]` and
# `Creation complete [id=...]` lines.
#
# For every secret in <project> whose name ends in `-principals`, this reads
# the latest version and, for each string value at any depth, prints
# `::add-mask::<value>` and `::add-mask::<address>`, the value with its type
# prefix (`group:`, `user:`, `serviceAccount:`) removed. The Actions runner
# masks both in every later log line of the job. Masks cover logs only, so it
# also writes the values and addresses, one per line, to <out-file>, from
# which .github/scripts/redact-principals.js strips them out of the plan and
# apply comments and job summaries. Nothing else prints a value.
#
# It fails if listing the secrets or reading any of them fails, if a secret
# is not a JSON object, or if a value is shorter than 4 characters or spans
# lines, since the runner cannot mask either. A project with no principals
# secrets writes an empty <out-file>. The caller's identity needs
# secretmanager.secrets.list on the project (roles/viewer holds it) and
# secretmanager.versions.access on each principals secret.
#
# Usage: scripts/mask-principals.sh <project> <out-file>
#   scripts/mask-principals.sh example-project "$RUNNER_TEMP/principal-addresses"
set -euo pipefail

print_usage() {
    sed -n '/^# Usage:/,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d;s/^# \{0,1\}//'
}

for arg in "$@"; do
    case "$arg" in
    -h | --help)
        print_usage
        exit 0
        ;;
    -*)
        echo "Unrecognized option: $arg" >&2
        print_usage >&2
        exit 1
        ;;
    esac
done
if [ $# -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
    echo "Expected 2 non-empty arguments: project out-file." >&2
    print_usage >&2
    exit 1
fi

project="$1"
out_file="$2"

command -v gcloud >/dev/null || { echo "::error::gcloud not found." >&2; exit 1; }
command -v jq >/dev/null || { echo "::error::jq not found." >&2; exit 1; }

# A plain assignment, so a failed listing stops the script rather than
# passing as a project with no secrets.
listing="$(gcloud secrets list --project="$project" --format='value(name.basename())')" || {
    echo "::error::Could not list the secrets in $project." >&2
    exit 1
}
secrets=()
while read -r name; do
    case "$name" in
    *-principals) secrets+=("$name") ;;
    esac
done <<<"$listing"

values=()
for name in ${secrets[@]+"${secrets[@]}"}; do
    payload="$(gcloud secrets versions access latest --secret="$name" --project="$project")" || {
        echo "::error::Could not read the latest version of $name in $project. The identity needs roles/secretmanager.secretAccessor on it." >&2
        exit 1
    }
    # The error messages name the secret, never the value.
    members="$(jq -r --arg name "$name" '
        if type != "object" then error("\($name) is not a JSON object") else . end
        | .. | strings
        | if test("[\r\n]") or length < 4 then error("\($name) holds a value shorter than 4 characters or spanning lines") else . end
    ' <<<"$payload")" || {
        echo "::error::$name in $project is not a JSON object of maskable IAM members." >&2
        exit 1
    }
    while read -r member; do
        [ -z "$member" ] && continue
        address="$member"
        while [[ "$address" =~ ^[A-Za-z]+:(.*)$ ]]; do
            address="${BASH_REMATCH[1]}"
        done
        if [ "${#address}" -lt 4 ]; then
            echo "::error::$name holds a member whose address is shorter than 4 characters." >&2
            exit 1
        fi
        values+=("$member" "$address")
    done <<<"$members"
done

umask 077
: >"$out_file"
if [ "${#values[@]}" -gt 0 ]; then
    printf '%s\n' "${values[@]}" | sort -u >"$out_file"
fi
while read -r value; do
    [ -z "$value" ] && continue
    echo "::add-mask::$value"
done <"$out_file"
echo "Masked $(wc -l <"$out_file" | tr -d ' ') principal value(s) from ${#secrets[@]} secret(s) in $project."
