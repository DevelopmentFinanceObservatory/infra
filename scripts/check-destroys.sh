#!/usr/bin/env bash
# Guardrail against accidental data loss in CI (issue #18).
#
# Fails when a saved Terraform plan would DELETE or REPLACE a data-bearing
# ("protected") resource — the ones whose loss is destructive and hard to
# recover: Spanner instances/databases, Cloud SQL instances/databases, GCS
# buckets, BigQuery datasets and reservations, log buckets, and Secret Manager
# secrets. A replace shows up as a "delete" action too, so this catches
# destroy-and-recreate, not just plain destroy.
#
# VPC networks, subnets, reserved internal addresses, and the DNS managed
# zones and record sets that resolve the Cloud SQL PSC name inside them are
# protected too, standing in for `prevent_destroy` on the consumer-psc-network
# module's resources. That module is pre-release and carries none, since
# recreating any of them costs nothing and the block would obstruct the
# iteration this stage is for.
#
# Ephemeral resources are intentionally ignored: the dcp stack replaces a
# null_resource on every run, so a blanket "any delete fails" check would
# red-flag every dcp PR. Only the anchored types below trip the guard. Extend
# the list as new data-bearing resources appear.
#
# The caller decides what an "allow-destroy" override means; this script only
# reports and signals via its exit code.
#
# Usage: check-destroys.sh <planfile>   # run from the stack's terraform dir
# Exit:  0 = safe, 3 = protected destroy(s) found, other = error.
set -euo pipefail

plan="${1:?usage: check-destroys.sh <planfile>}"
protected='^google_(spanner_instance|spanner_database|sql_database_instance|sql_database|storage_bucket|bigquery_dataset|bigquery_reservation|logging_project_bucket_config|secret_manager_secret|compute_network|compute_subnetwork|compute_address|dns_managed_zone|dns_record_set)$'

# Write the JSON to a file first rather than piping: the setup-terraform wrapper
# can interleave its own lines into a piped stdout and break jq parsing.
terraform show -json "$plan" >"$plan.json"

destroys="$(jq -r --arg re "$protected" '
  .resource_changes[]
  | select(.change.actions | index("delete"))
  | select(.type | test($re))
  | "  \(.change.actions | join("+"))\t\(.address)\t(\(.action_reason // "n/a"))"
' "$plan.json")"

if [ -n "$destroys" ]; then
  echo "Protected-resource destroys/replacements in this plan:"
  echo "$destroys"
  exit 3
fi

echo "No protected-resource destroys in this plan."
