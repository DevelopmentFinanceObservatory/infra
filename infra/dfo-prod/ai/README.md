# ai (prod)

Prod's copy of the ai stack: the `dfo-prod-ai` Cloud Run service, its definition and materialisation buckets, its session database on the shared Cloud SQL instance, and the studio and MCP API token secrets. The `.tf` files are symlinks to `infra/stacks/ai`; `infra/dfo-dev/ai/README.md` describes what they build. This directory holds prod's backend, tfvars, and lock file.

## Apply order

Ai applies after `foundation`, `platform`, `dcp`, and `apis`, and before `website`, which reads this stack's token secrets. The service mounts the `apis` stack's `dfo-prod-datasets-first-party-principal` secret, so `apis` must have created it, and grants its runtime account `roles/run.invoker` on `dfo-prod-apis`, so that service must exist. The commented lines in `env.auto.tfvars` take values from those stacks' outputs.

## Made by hand first

Four secrets, each with at least one version:

- `dfo-prod-ai-gemini-api-key`, the service's Gemini API key, from its own AI Studio project on the DFO billing account. `data.google_secret_manager_secret.gemini` fails plan until it exists.
- `dfo-prod-langfuse-public-key` and `dfo-prod-langfuse-secret-key`, a Langfuse Cloud EU key pair.
- `dfo-prod-ai-principals`, the studio and MCP token readers, which `scripts/bootstrap-principals.sh` writes, as `infra/dfo-dev/ai/README.md` "Principals secret" describes, with `prod-fin-observatory` and `dfo-prod-ai-principals` as its arguments. Both objects are empty until someone needs a token. Plan fails while the secret does not exist.

## Langfuse export

`env.auto.tfvars` sets `langfuse_export_enabled = true`, so prod builds the `dfo-prod-langfuse-export` Job, its hourly trigger and the `langfuse_export` dataset (`infra/dfo-dev/ai/README.md`, "Langfuse export"). `scripts/handoff.sh dfo-prod ai` writes the Job name to dfo-ai's `production` GitHub Environment as `JOB_LANGFUSE_EXPORT`, from this stack's `langfuse_export_job_name` output. Run it after the apply that creates the Job. Until the variable is set, dfo-ai's deploy skips the Job's image update and the Job keeps its bootstrap image, and a bootstrap image older than the export module fails every hourly run.

### Langfuse blob storage export

The same flag builds the bucket Langfuse's blob storage export writes to and its writer account (`infra/dfo-dev/ai/README.md`, "Langfuse export"). The HMAC key is made by hand after the apply, so it never enters Terraform state.

1. Read the writer account and bucket from the outputs: `terraform output langfuse_export_blob_writer_email` and `terraform output langfuse_export_bucket_name`.
2. Create the key into a file only your user can read: `(umask 077 && gcloud storage hmac create <WRITER_EMAIL> --project=<PROJECT_ID> --format=json > ~/.config/langfuse/gcs-hmac.json)`. The file holds `metadata.accessId` and `secret`, which Google shows only once. Keep the secret out of the repo and out of chat.
3. In Langfuse, open Project Settings > Integrations > Blob Storage and set:
   - Storage provider: S3-compatible storage.
   - Endpoint: `https://storage.googleapis.com`.
   - Region: `auto`.
   - Bucket name: `<BUCKET_NAME>`.
   - Prefix: a path ending in `/`, for example `langfuse/`.
   - Access key ID and secret access key: the HMAC access ID and secret.
   - File type: Parquet.
   - Frequency: hourly.
   - Export mode: Full history.
   - Field groups: core, basic, time, model, usage, metrics and trace_context. Leave io, metadata, tools and prompt off, because prompts, answers, metadata and tool arguments stay out of GCS and BigQuery.
4. Click Validate, then save, and delete `~/.config/langfuse/gcs-hmac.json`. Langfuse then holds the only copy of the secret; a lost key is replaced by a new one.
5. Check that Parquet files appear under `gs://<BUCKET_NAME>/<PREFIX><LANGFUSE_PROJECT_ID>/observations_v2/` after the first hourly run.

Retire a key with `gcloud storage hmac update <ACCESS_ID> --deactivate`, then `gcloud storage hmac delete <ACCESS_ID>`.
