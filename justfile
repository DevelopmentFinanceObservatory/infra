# DFO Infra — Developer Commands
# Run 'just' or 'just --list' to see all targets.
#
# First time on a new machine:
#   just auth        # authenticate gcloud + application-default
#   just bootstrap   # terraform init
#
# Terraform is organised as one root per environment x stack (see README.md).
# Recipes default to the dcp stack; override from the command line:
#   just STACK=foundation plan
#   just ENV=dfo-dev STACK=ai apply
#   just ENV=dfo-prod STACK=dcp plan      # prod, in its own GCP project

# Configuration (override from the command line)
ENV           := "dfo-dev"
STACK         := "dcp"
# The GCP project follows ENV, so one override picks both. PROJECT= still
# overrides it from the command line.
PROJECT       := if ENV == "dfo-dev" { "dev-fin-observatory" } else if ENV == "dfo-prod" { "prod-fin-observatory" } else { error("unknown ENV '" + ENV + "' (expected dfo-dev or dfo-prod)") }
DC_KEY_SECRET := "dc-api-key"
STUDIO_TOKEN_SECRET := ENV + "-studio-api-token"

# The dcp stack's pinned upstream module version (infra/stacks/dcp/main.tf's
# source ref). init-db and load both invoke datacommons-cli, and an unpinned
# uvx call floats to whatever's latest on PyPI regardless of the module ref
# this repo is actually running.
DCP_CLI_VERSION := "1.1.5"

# datacommons-cli finds its project, Spanner instance and database,
# ingestion-helper URL and workflow service account by running
# `terraform output -json` in its own working directory. It offers no
# flag, environment variable, config file or directory walk for any of
# them, and just runs a recipe from this file's directory whatever
# directory the operator invoked it from. Hence the `cd {{TF_DIR}} &&`
# on every recipe that reaches the CLI.
TF_DIR  := "infra" / ENV / STACK

# GCP Application Default Credentials (what Terraform's GCS backend uses)
GCP_ADC := env_var("HOME") / ".config/gcloud/application_default_credentials.json"

_default:
    @just --list --unsorted

# ── Setup ─────────────────────────────────────

# Authenticate gcloud + application-default credentials
auth:
    gcloud auth login
    gcloud auth application-default login

# terraform init for the selected stack, and the first thing to run after
# cloning (defaults to dcp, override with STACK=, e.g. `just STACK=platform
# bootstrap`). A brand-new stack's state prefix has no state object yet, and
# creating one is a write the read-only CI planner can't make. So this also
# has to be run by hand, once, whenever a new stack's first PR needs `plan`
# to succeed.
[doc("terraform init a stack for the first time, by hand")]
bootstrap: _check-gcloud
    cd {{TF_DIR}} && terraform init

# Grant a collaborator read access to the DC API key secret:
#   just grant-dc-key alice@one.org
[doc("Grant a collaborator read access to the DC API key secret")]
grant-dc-key email: _check-gcloud
    gcloud secrets add-iam-policy-binding {{DC_KEY_SECRET}} --member='user:{{email}}' --role='roles/secretmanager.secretAccessor' --project={{PROJECT}}

# Print the studio API token, for an account listed in the ai stack's
# studio_token_readers. The token goes to stdout and everything else to
# stderr, so `export STUDIO_API_TOKEN=$(just studio-token)` works. Needs
# only `gcloud auth login`, not application-default credentials.
[doc("Print the studio API token (for accounts in studio_token_readers)")]
studio-token:
    #!/usr/bin/env bash
    set -euo pipefail
    account=$(gcloud auth list --filter=status:ACTIVE --format='value(account)')
    if [ -z "$account" ]; then
        echo "Error: no active gcloud account. Run 'gcloud auth login' with your granted account." >&2
        exit 1
    fi
    echo "Reading {{STUDIO_TOKEN_SECRET}} in {{PROJECT}} as $account" >&2
    gcloud secrets versions access latest --secret={{STUDIO_TOKEN_SECRET}} --project={{PROJECT}} \
        || { echo "Hint: check $account is the account listed in studio_token_readers ('gcloud config set account <email>'), and that 'gcloud config get billing/quota_project' is unset." >&2; exit 1; }

# Install dev tooling (uv sync + pre-commit hooks)
install:
    uv sync
    uv run pre-commit install

# ── Terraform ─────────────────────────────────

# terraform init for the selected stack: just STACK=foundation init
init: _check-gcloud
    cd {{TF_DIR}} && terraform init

# terraform plan for the selected stack
plan: _check-gcloud
    cd {{TF_DIR}} && terraform plan

# terraform apply for the selected stack
apply: _check-gcloud
    cd {{TF_DIR}} && terraform apply

# Break-glass dcp deploy: apply a built services image directly against live
# state with your own gcloud credentials, then pin it. The routine path is
# dfo-dcp's CI opening a PR against image.auto.tfvars. Use this recipe
# only when that path is unavailable: it skips the PR, the plan-comment
# trail, and the destroy guard the automated path runs.
# The pin CI writes is a digest, so pass one here too, to keep the
# committed pin matching the automated shape.
# Usage: just deploy northamerica-northeast1-docker.pkg.dev/.../dfo-services-image@sha256:<digest>
[doc("Pin a dcp services image by digest, bypassing the automated PR")]
deploy image: _check-gcloud
    #!/usr/bin/env bash
    set -euo pipefail
    TFVARS="infra/{{ENV}}/dcp/image.auto.tfvars"
    # 1. Apply with the new image (Terraform shows the diff and asks to confirm).
    ( cd "infra/{{ENV}}/dcp" && terraform apply -var="datacommons_services_image={{image}}" )
    # 2. On success, pin the image in image.auto.tfvars (replace the existing
    #    line; nothing else belongs in that file).
    sed -i.bak -E "s|^[[:space:]]*datacommons_services_image[[:space:]]*=.*|datacommons_services_image = \"{{image}}\"|" "$TFVARS"
    # sed exits 0 even if it matched nothing, so verify the line actually
    # landed instead of trusting the substitution. Without this check, a
    # reshaped assignment line would leave the file untouched, and this
    # recipe would print "Deployed" with the apply already live and the
    # committed pin wrong.
    if ! grep -qF "datacommons_services_image = \"{{image}}\"" "$TFVARS"; then
        echo "Error: $TFVARS still doesn't contain the expected pin line after sed." >&2
        echo "The apply above already ran against live state — fix $TFVARS by hand" >&2
        echo "and commit it, or the committed pin will disagree with what's deployed." >&2
        rm -f "$TFVARS.bak"
        exit 1
    fi
    rm -f "$TFVARS.bak"
    terraform fmt "$TFVARS"
    echo ""
    echo "Deployed. Commit the updated image.auto.tfvars in a PR so CI applies the pin on merge."
    URL=$(cd "infra/{{ENV}}/dcp" && terraform output -raw datacommons_service_url 2>/dev/null || true)
    [ -n "$URL" ] && echo "App: $URL/app"

# Show terraform outputs for the selected stack (add a name for one: just output spanner_database_id)
output *name: _check-gcloud
    cd {{TF_DIR}} && terraform output {{name}}

# terraform fmt across every stack and module
fmt:
    terraform fmt -recursive infra

# Regenerate the dcp stack's CLI-owned scaffolding (main.tf, variables.tf,
# outputs.tf, README.md) at a new upstream version and copy the safe files
# over the tracked ones: the .tf files into infra/stacks/dcp, which every
# environment's dcp directory links to, and README.md into the ENV's own dcp
# directory. Bump DCP_CLI_VERSION above, then run `just dcp-scaffold`. It refuses a version argument that disagrees with
# DCP_CLI_VERSION, keeping the CLI version and the module ref in lockstep.
# It never touches backend.tf or terraform.tfvars. The CLI's backend.tf
# assumes one stack per instance and would point this stack at empty state
# (see infra/dfo-dev/dcp/dfo.README.md). This only stages the files. It
# doesn't plan or apply. Read the diff, then run `just plan` and check for
# relocated resources that need `moved` blocks.
[doc("Regenerate the dcp stack's CLI-owned Terraform scaffolding")]
dcp-scaffold version=DCP_CLI_VERSION:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{version}}" != "{{DCP_CLI_VERSION}}" ]; then
        echo "Error: asked for {{version}} but DCP_CLI_VERSION is {{DCP_CLI_VERSION}}." >&2
        echo "The CLI version and the module ref must move together — bump" >&2
        echo "DCP_CLI_VERSION in this justfile first, then re-run." >&2
        exit 1
    fi
    DCP_DIR="infra/{{ENV}}/dcp"
    CODE_DIR="infra/stacks/dcp"
    GEN_DIR="$(mktemp -d)"
    trap 'rm -rf "$GEN_DIR"' EXIT
    cd "$GEN_DIR"
    printf 'y\n\n' | uvx --no-cache --from "datacommons-cli=={{version}}" \
        --with "datacommons-admin=={{version}}" datacommons admin init \
        --project-id {{PROJECT}} --instance-name {{ENV}} --force
    cd - >/dev/null
    # This guardrail fails on any file the CLI emits that the copy loop
    # below doesn't know about, rather than silently dropping it. It's the
    # one check here that inspects what the CLI actually wrote. `ls -A` so
    # a new dotfile from the CLI still shows up, and `LC_ALL=C sort` so
    # the comparison stays independent of the operator's locale (a plain
    # `sort` collates case-insensitively under most locales, which would
    # put README.md in the middle and break the match against EXPECTED).
    EXPECTED="README.md backend.tf main.tf outputs.tf terraform.tfvars variables.tf"
    ACTUAL="$(cd "$GEN_DIR/{{ENV}}" && ls -A | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
    if [ "$ACTUAL" != "$EXPECTED" ]; then
        echo "Error: the CLI emitted an unexpected file set into $GEN_DIR/{{ENV}}/." >&2
        echo "  expected: $EXPECTED" >&2
        echo "  got:      $ACTUAL" >&2
        echo "Update the copy loop below before continuing." >&2
        exit 1
    fi
    for f in main.tf variables.tf outputs.tf; do
        cp "$GEN_DIR/{{ENV}}/$f" "$CODE_DIR/$f"
    done
    cp "$GEN_DIR/{{ENV}}/README.md" "$DCP_DIR/README.md"
    # These working-tree checks catch uncommitted edits already sitting in
    # backend.tf or dfo.* files before this recipe ran, edits that would
    # otherwise blend into the diff --stat below and look like part of
    # this change. The copy loop above only writes main.tf, variables.tf,
    # outputs.tf and README.md, so it can't produce a diff in these files.
    if ! git diff --quiet -- "$DCP_DIR/backend.tf"; then
        echo "Error: backend.tf has uncommitted changes. Commit or revert them" >&2
        echo "with 'git checkout -- $DCP_DIR/backend.tf' before continuing." >&2
        exit 1
    fi
    if ! git diff --quiet -- "$DCP_DIR"/dfo* "$CODE_DIR"/dfo*; then
        echo "Error: a dfo.* file has uncommitted changes. Commit or revert" >&2
        echo "them before continuing." >&2
        exit 1
    fi
    echo ""
    git diff --stat -- "$DCP_DIR" "$CODE_DIR"
    echo ""
    echo "Read the diff above, then run 'terraform init' in $DCP_DIR (the"
    echo "module source ref moved) before 'just plan', and check the plan for"
    echo "relocated resources that need 'moved' blocks."

# terraform validate the selected stack (offline — no credentials needed)
validate:
    cd {{TF_DIR}} && terraform validate

# ── Handoff ───────────────────────────────────

# Copy every deploy variable and secret a service repo's workflows read
# (deploy_values in scripts/deploy-targets.sh) from Terraform outputs into its
# GitHub Environment. Run after the foundation + <stack> stacks are applied,
# and apis too for dcp. Needs a GitHub login (gh auth login) in addition to
# gcloud. ENV picks the target: `just handoff apis` writes to
# ONEcampaign/dfo-apis's `dev` environment, and `just ENV=dfo-prod handoff
# apis` to DevelopmentFinanceObservatory/apis's `production`. `just handoff`
# defaults to the ai stack. The repo, GitHub Environment and deploy branch
# come from scripts/deploy-targets.sh. `just handoff infra` sets this repo's
# own WIF repo variables instead, and needs only foundation applied.
[doc("Copy deploy config from Terraform outputs into a service repo")]
handoff stack="ai": _check-gcloud
    scripts/handoff.sh {{ENV}} {{stack}}

# Set the dfo-reader and dfo-release App credentials in ENV's GitHub org,
# and create the release App's environments in prod. Needs a GitHub login
# (gh auth login) and the Apps' key files; missing values are prompted for.
#   just setup-github-apps --dry-run
#   just ENV=dfo-prod setup-github-apps --reader-key ~/keys/reader.pem --reader-client-id Iv23li...
[doc("Set the GitHub App credentials and release environments for ENV")]
setup-github-apps *args:
    scripts/setup-github-apps.sh {{ENV}} {{args}}

# ── Data ──────────────────────────────────────

# One-time bootstrap for a brand-new dcp database. Creates the schema.
# --init-only skips the seed step (now 'just seed-db') but still runs
# migrations, matching upstream's own guard message treating initialize,
# migrate and seed as independently runnable steps.
# The already-initialised check runs Spanner locally under your ADC and
# fails open on a permissions or connectivity error. On that path,
# initialize_database() still POSTs to the ingestion-helper's
# database/initialize. Migrations find nothing pending on an up-to-date
# schema and skip. The CLI reports "Successfully initialized Spanner
# database!" with no sign anything was unusual. What database/initialize
# does to an existing database isn't established from source. It runs
# server-side in the ingestion-helper image, under the impersonated
# workflow service account, so a 403 on your principal doesn't restrain it.
# Only run this against a known-fresh database. Needs
# roles/iam.serviceAccountTokenCreator on the ingestion workflow service
# account (init call) and Spanner read (e.g. roles/spanner.databaseReader)
# on your principal (initialised check). Terraform grants neither by
# default (see README.md).
[confirm("The already-initialised check fails open on a permissions or connectivity error. On that path this still calls the ingestion-helper's database/initialize against a possibly-live database and reports success regardless — migrations are safe (they skip if the schema is current), but database/initialize's own effect on an existing database isn't established. Continue only if this database is known to be fresh.")]
[doc("Bootstrap schema for a brand-new dcp database")]
init-db: _check-gcloud
    cd {{TF_DIR}} && uvx --from "datacommons-cli=={{DCP_CLI_VERSION}}" --with "datacommons-admin=={{DCP_CLI_VERSION}}" datacommons admin init-db --init-only

# Migrate the dcp database schema forward. Run only after 'terraform
# apply' has finished, not just merged. The apply workflow fires
# asynchronously, and the migration locks through endpoints that exist
# only on the matching ingestion-helper image. Acquires that lock through
# impersonated credentials (needs roles/iam.serviceAccountTokenCreator on
# the ingestion workflow service account) but talks to Spanner as you
# (needs roles/spanner.databaseAdmin on your own principal). Terraform
# grants neither by default. Migrations are forward-only. The CLI's prompt
# recommends and confirms a backup but doesn't take one. Back up Spanner
# yourself before proceeding.
[doc("Migrate the dcp database schema forward")]
migrate-db: _check-gcloud
    cd {{TF_DIR}} && uvx --from "datacommons-cli=={{DCP_CLI_VERSION}}" --with "datacommons-admin=={{DCP_CLI_VERSION}}" datacommons admin migrate-db

# Re-run the platform's base geographic and schema seeds. 'just load'
# stages and ingests a custom dataset. This only refreshes Base DC's own
# seed data. It goes through the ingestion-helper service, not Spanner
# directly. It needs roles/iam.serviceAccountTokenCreator on the ingestion
# workflow service account, and no Spanner role at all. Unguarded and
# unprompted, an unconditional reseed call with no already-seeded check
# and no confirmation. Typing the command is the only thing standing
# between you and it running.
[doc("Re-run Base DC's geographic and schema seeds")]
seed-db: _check-gcloud
    cd {{TF_DIR}} && uvx --from "datacommons-cli=={{DCP_CLI_VERSION}}" --with "datacommons-admin=={{DCP_CLI_VERSION}}" datacommons admin seed-db

# Stage a dataset into the ingestion bucket + trigger ingestion: just load data/oecd-wage
load dataset: _check-gcloud
    DCP_CLI_VERSION={{DCP_CLI_VERSION}} scripts/load.sh {{dataset}} {{ENV}}

# List available datasets
datasets:
    @ls -d data/*/ | sed 's|/$||'

# ── Dev ───────────────────────────────────────

# Run all pre-commit hooks across the repo
check:
    uv run pre-commit run --all-files

# Lint Python with ruff
lint:
    uv run ruff check .

# Format Python with ruff
format:
    uv run ruff format .

# ── Internal ──────────────────────────────────

_check-gcloud:
    #!/usr/bin/env bash
    if ! gcloud auth list --filter=status:ACTIVE --format='value(account)' | grep -q .; then
        echo "Error: no active gcloud account. Run 'just auth'."
        exit 1
    fi
    if [ ! -f "{{GCP_ADC}}" ]; then
        echo "Error: GCP Application Default Credentials not found."
        echo "Run 'just auth' (or 'gcloud auth application-default login')."
        exit 1
    fi
