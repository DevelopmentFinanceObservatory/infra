# ai (prod)

Prod's copy of the ai stack: the `dfo-prod-ai` Cloud Run service, its definition and materialisation buckets, its session database on the shared Cloud SQL instance, and the studio and MCP API token secrets. The `.tf` files are symlinks to `infra/stacks/ai`; `infra/dfo-dev/ai/README.md` describes what they build. This directory holds prod's backend, tfvars, and lock file.

## Apply order

Ai applies after `foundation`, `platform`, `dcp`, and `apis`, and before `website`, which reads this stack's token secrets. The service mounts the `apis` stack's `dfo-prod-datasets-first-party-principal` secret, so `apis` must have created it, and grants its runtime account `roles/run.invoker` on `dfo-prod-apis`, so that service must exist. The commented lines in `env.auto.tfvars` take values from those stacks' outputs.

## Made by hand first

Three secrets, each with at least one version:

- `dfo-prod-gemini-api-key`, the Gemini API key, shared with the `apis` stack.
- `dfo-prod-langfuse-public-key` and `dfo-prod-langfuse-secret-key`, a Langfuse Cloud EU key pair.
