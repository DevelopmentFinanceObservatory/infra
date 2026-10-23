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
# `::add-mask::` for the value and for its address, the value with its type
# prefix (`group:`, `user:`, `serviceAccount:`) removed. Each of the two is
# also masked lower-cased, since the provider and IAM lower-case emails in
# ids and policy reads, and URL-encoded (`@` as `%40`, `:` as `%3A`) in both
# cases. The Actions runner masks them in every later log line of the job.
# Masks cover logs only, so it also writes every form, one per line, to
# <out-file>, from which .github/scripts/redact-principals.js strips them out
# of the plan and apply comments and job summaries. Nothing else prints a
# value.
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
    # Each member and its address, the member with its type prefixes
    # removed, in four more forms: lower-cased, since the provider and IAM
    # lower-case emails in ids and policy reads, and URL-encoded with
    # encodeURIComponent's escapes (jq's @uri also escapes !'()*), from each
    # case. The error messages name the secret, never the value.
    forms="$(jq -r --arg name "$name" '
        def enc: @uri | gsub("%21"; "!") | gsub("%27"; "'"'"'") | gsub("%28"; "(") | gsub("%29"; ")") | gsub("%2A"; "*");
        if type != "object" then error("\($name) is not a JSON object") else . end
        | .. | strings
        | if test("[\r\n]") or length < 4 then error("\($name) holds a value shorter than 4 characters or spanning lines") else . end
        | [., sub("^([A-Za-z]+:)+"; "")]
        | if (.[1] | length) < 4 then error("\($name) holds a member whose address is shorter than 4 characters") else . end
        | .[]
        | ., ascii_downcase, enc, (enc | ascii_downcase), (ascii_downcase | enc)
    ' <<<"$payload")" || {
        echo "::error::$name in $project is not a JSON object of maskable IAM members." >&2
        exit 1
    }
    while read -r form; do
        [ -n "$form" ] && values+=("$form")
    done <<<"$forms"
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
