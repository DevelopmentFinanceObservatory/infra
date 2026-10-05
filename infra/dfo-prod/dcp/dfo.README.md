# dcp, prod

The prod root for the Data Commons stack. Every `.tf` file here is a symlink into `infra/stacks/dcp`, and `infra/dfo-dev/dcp/dfo.README.md` documents that code. This directory holds the backend, the lock file, and the prod values: `dfo.auto.tfvars` and the machine-written `image.auto.tfvars`.

## Apply order

Apply after `foundation` and `platform`, and before `apis`. The datasets and presentation databases live on platform's Cloud SQL instance. The `apis` stack reads this stack's outputs (`datacommons_service_url`, the bucket names, the migrator secret ids) and grants its runtime user CONNECT on the two databases created here.

## Hand-made prerequisites

- Secret Manager secret `dc-api-key` with a non-empty version holding the Data Commons API key. `null_resource.dc_key_guard` in `dfo.tf` fails plan without it.
- Secret Manager secret `dfo-prod-gemini-api-key`. `null_resource.search_api_gemini_key` mounts it on the Data Commons service after each apply.

`image.auto.tfvars` starts at `datacommons_services_image = null`, which deploys upstream's `datacommons-services` image for `dcp_version`. The first run of dfo-dcp's `deploy-prod.yml` opens a pin PR from `deploy/dcp-prod` that replaces it.
