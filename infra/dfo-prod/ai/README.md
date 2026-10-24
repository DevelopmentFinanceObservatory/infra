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
