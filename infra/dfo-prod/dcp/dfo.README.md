# dcp, prod

The prod root for the Data Commons stack. Every `.tf` file here is a symlink into `infra/stacks/dcp`, and `infra/dfo-dev/dcp/dfo.README.md` documents that code. This directory holds the backend, the lock file, and the prod values: `dfo.auto.tfvars` and the machine-written `image.auto.tfvars`.

## Apply order

Apply after `foundation` and `platform`, and before `apis`. The datasets and presentation databases live on platform's Cloud SQL instance. The `apis` stack reads this stack's outputs (`datacommons_service_url`, the bucket names, the migrator secret ids) and grants its runtime user CONNECT on the two databases created here.

## Hand-made prerequisites

- Secret Manager secret `dc-api-key` with a non-empty version holding the Data Commons API key. `null_resource.dc_key_guard` in `dfo.tf` fails plan without it.
- Secret Manager secret `dfo-prod-dcp-gemini-api-key`, the Gemini key the DFO prototype app reads, with a version holding a key from its own AI Studio project on the DFO billing account. `data.google_secret_manager_secret.search_api_gemini` fails plan until the secret exists, and `null_resource.search_api_gemini_key` mounts it on the Data Commons service after each apply. The serving account `dfo-prod-dc-srvs-sa` reads it through `google_secret_manager_secret_iam_member.serving_sa_gemini_key`, a grant on this one secret.

`image.auto.tfvars` starts at `datacommons_services_image = null`, which deploys upstream's `datacommons-services` image for `dcp_version`. The first run of dfo-dcp's `deploy-prod.yml` opens a pin PR from `deploy/dcp-prod` that replaces it.

## Reaching the service

`dfo-prod-dc-datacommons-service` grants `roles/run.invoker` only to the identities in `infra/stacks/apis/dcp_access.tf`, so a browser or an MCP client gets 403 at its URL. A person with invoke rights on the project reaches the web UI, `/prototype` and `/mcp` through a local proxy:

```
gcloud run services proxy dfo-prod-dc-datacommons-service --region europe-west1 --project prod-fin-observatory
```

If a caller breaks after an apply, this command admits every caller until you remove the binding:

```
gcloud run services add-iam-policy-binding dfo-prod-dc-datacommons-service --region europe-west1 --project prod-fin-observatory --member=allUsers --role=roles/run.invoker
```

Terraform ignores that binding, so remove it with `remove-iam-policy-binding` and the same arguments once the caller has its grant.

## Retired preprocessing job

DCP 1.1.6 runs ingestion preprocessing on Cloud Batch, and the stack module no longer declares the Cloud Run job `dfo-prod-dc-ingestion-preprocessing-job`. Prod state held that job with `deletion_protection = true`, which blocks a Terraform destroy, so the `removed` block in `dfo.tf` makes Terraform forget it instead. Once an apply has run with that block, delete the job:

```sh
gcloud run jobs delete dfo-prod-dc-ingestion-preprocessing-job --project=prod-fin-observatory --region=europe-west1
```
