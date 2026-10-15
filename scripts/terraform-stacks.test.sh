#!/usr/bin/env bash
# Scenario tests for terraform-stacks.sh. Not wired into CI or pre-commit.
# Run by hand after touching the script:
#   scripts/terraform-stacks.test.sh
#
# The cases run against a fixture tree in a temporary directory with the
# shared-code layout: stack code in infra/stacks/<stack>, per-environment
# roots that symlink to it, and a dev-only pipelines root.
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/terraform-stacks.sh"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/infra/modules/cloud-run-service" "$FIXTURE/infra/modules/consumer-psc-network" \
    "$FIXTURE/infra/modules/github-deployer" "$FIXTURE/infra/modules/nested"
printf 'module "n" {\n  source = "../nested"\n}\n' >"$FIXTURE/infra/modules/github-deployer/main.tf"
touch "$FIXTURE/infra/modules/README.md"

mkdir -p "$FIXTURE/infra/stacks/apis" "$FIXTURE/infra/stacks/foundation" "$FIXTURE/infra/stacks/dcp"
printf 'module "s" {\n  source = "../../modules/cloud-run-service"\n}\n' >"$FIXTURE/infra/stacks/apis/main.tf"
printf 'module "n" {\n  source  =  "../../modules/consumer-psc-network"\n}\n' >"$FIXTURE/infra/stacks/apis/network.tf"
printf 'module "d" {\n  source = "../../modules/github-deployer"\n}\n' >"$FIXTURE/infra/stacks/foundation/main.tf"
printf 'module "stack" {\n  source = "git::https://example.invalid/stack?ref=v1"\n}\n' >"$FIXTURE/infra/stacks/dcp/main.tf"

for env in dfo-dev dfo-prod; do
    for stack in apis foundation dcp; do
        mkdir -p "$FIXTURE/infra/$env/$stack"
        for f in "$FIXTURE/infra/stacks/$stack"/*.tf; do
            ln -s "../../stacks/$stack/$(basename "$f")" "$FIXTURE/infra/$env/$stack/$(basename "$f")"
        done
        touch "$FIXTURE/infra/$env/$stack/env.auto.tfvars"
    done
done
mkdir -p "$FIXTURE/infra/dfo-dev/pipelines"
touch "$FIXTURE/infra/dfo-dev/pipelines/main.tf"

failures=0

# expect <expected-output> <label> <args...> -- paths come from $PATHS.
expect() {
    local expected="$1" label="$2"
    shift 2
    local got status
    set +e
    got="$(cd "$FIXTURE" && printf '%s' "$PATHS" | "$SCRIPT" "$@" 2>/dev/null)"
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
        echo "FAIL: $label -- exited $status"
        failures=$((failures + 1))
    elif [ "$got" != "$expected" ]; then
        echo "FAIL: $label -- got '$got', expected '$expected'"
        failures=$((failures + 1))
    else
        echo "ok: $label -> $got"
    fi
}

# expect_failure <label> <args...> -- asserts a non-zero exit and no stdout.
expect_failure() {
    local label="$1"
    shift
    local got status
    set +e
    got="$(cd "$FIXTURE" && printf '%s' "$PATHS" | "$SCRIPT" "$@" 2>/dev/null)"
    status=$?
    set -e
    if [ "$status" -eq 0 ] || [ -n "$got" ]; then
        echo "FAIL: $label -- exited $status with '$got', expected a failure and no output"
        failures=$((failures + 1))
    else
        echo "ok: $label -> fails, as expected"
    fi
}

PATHS=""
expect dfo-dev "dev branch" environment dev
expect dfo-prod "main branch" environment main
expect_failure "feature branch" environment feature/x
expect_failure "full ref" environment refs/heads/main
expect_failure "empty branch" environment ""

PATHS="infra/stacks/apis/main.tf"
expect '["apis"]' "shared stack code, dev" changed dfo-dev
expect '["apis"]' "shared stack code, prod" changed dfo-prod

PATHS="infra/dfo-prod/dcp/image.auto.tfvars"
expect '[]' "prod root ignored by dev" changed dfo-dev
expect '["dcp"]' "prod root changes prod" changed dfo-prod

PATHS="infra/dfo-dev/apis/env.auto.tfvars"
expect '[]' "dev root ignored by prod" changed dfo-prod
expect '["apis"]' "dev root changes dev" changed dfo-dev

PATHS="infra/modules/consumer-psc-network/main.tf"
expect '["apis"]' "directly called module" changed dfo-prod

PATHS="infra/modules/nested/main.tf"
expect '["foundation"]' "module called through another module" changed dfo-dev

PATHS="infra/modules/README.md"
expect '[]' "file at the modules root" changed dfo-dev

PATHS="infra/modules/unused/main.tf"
expect '[]' "deleted module no stack calls" changed dfo-dev

PATHS="infra/dfo-dev/pipelines/main.tf"
expect '["pipelines"]' "dev-only pipelines in dev" changed dfo-dev
expect '[]' "dev-only pipelines in prod" changed dfo-prod

PATHS="$(printf '%s\n' infra/stacks/foundation/main.tf infra/stacks/dcp/main.tf infra/stacks/apis/x.tf docs/x.md)"
expect '["apis","dcp","foundation"]' "several stacks, each listed once" changed dfo-prod

PATHS="infra/stacks/apisx/main.tf"
expect '[]' "stack name prefix of another directory" changed dfo-dev

PATHS="infra/dfo-dev/website/main.tf"
expect_failure "removed stack root" changed dfo-dev
expect '[]' "removed stack root, allowed" changed dfo-dev --allow-removed
expect '[]' "removed dev root ignored by prod" changed dfo-prod
expect_failure "unknown changed option" changed dfo-dev --allow

PATHS="$(printf '%s\n' infra/dfo-dev/old-apis/main.tf infra/dfo-dev/apis/main.tf)"
expect_failure "renamed stack root" changed dfo-dev
expect '["apis"]' "renamed stack root, allowed, maps the new root" changed dfo-dev --allow-removed

PATHS="infra/dfo-dev/README.md"
expect '[]' "file at the environment root" changed dfo-dev

# A module directory deleted while stacks still call it selects those stacks,
# directly (apis) and through another module (foundation, via nested).
rm -rf "$FIXTURE/infra/modules/cloud-run-service" "$FIXTURE/infra/modules/nested"
PATHS="infra/modules/cloud-run-service/main.tf"
expect '["apis"]' "deleted module called directly" changed dfo-prod
PATHS="infra/modules/nested/main.tf"
expect '["foundation"]' "deleted module called through another module" changed dfo-dev

PATHS=""
expect '[]' "no paths" changed dfo-dev
expect_failure "missing environment directory" changed dfo-missing

if [ "$failures" -eq 0 ]; then
    echo "All scenarios passed."
    exit 0
else
    echo "$failures scenario(s) failed."
    exit 1
fi
