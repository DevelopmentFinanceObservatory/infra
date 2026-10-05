#!/usr/bin/env bash
# Stage a dataset into the ingestion input bucket and trigger ingestion.
#
# Usage: scripts/load.sh <dataset-dir> [env]
#   scripts/load.sh data/oecd-wage            # env defaults to dfo-dev
#   scripts/load.sh data/oecd-wage dfo-dev
#
# NOTE: ingestion reads ALL files in gs://<bucket>/ingestion/input/ against a
# single config.json. This script REPLACES the input dir contents with the given
# dataset so datasets are not accidentally mixed. Edit if you mean to combine them.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dataset="${1:?usage: load.sh <dataset-dir> [env]}"
env="${2:-dfo-dev}"
# Pins the datacommons-cli invocation below to the dcp stack's module
# version, set once in justfile's DCP_CLI_VERSION. Required rather than
# defaulted here so an unpinned direct run of this script fails loudly
# instead of floating to whatever's latest on PyPI.
dcp_cli_version="${DCP_CLI_VERSION:?DCP_CLI_VERSION not set; run via \"just load\", or export it to match the module ref in infra/stacks/dcp/main.tf}"
dataset_dir="$repo_root/$dataset"
[ -d "$dataset_dir" ] || { echo "no such dataset dir: $dataset_dir" >&2; exit 1; }
# ingest start requires --imports; read it from the dataset's own config
# rather than making the caller pass what's already declared there.
config="$dataset_dir/config.json"
[ -f "$config" ] || { echo "no such config.json: $config" >&2; exit 1; }
import_name="$(jq -r '.importName // empty' "$config")"
[ -n "$import_name" ] || { echo "no importName in $config" >&2; exit 1; }

cd "$repo_root/infra/$env/dcp"
bucket="$(terraform output -raw storage_artifacts_bucket_name)"
input="gs://$bucket/ingestion/input"

echo ">> Clearing $input/ ..."
gcloud storage rm "$input/**" 2>/dev/null || true
echo ">> Uploading $dataset/* -> $input/"
gcloud storage cp "$dataset_dir"/* "$input/"
echo ">> Triggering ingestion (watch the Workflow console link it prints)..."
uvx --from "datacommons-cli==$dcp_cli_version" --with "datacommons-admin==$dcp_cli_version" datacommons admin ingest start --imports "$import_name"
