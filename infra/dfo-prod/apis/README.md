# apis, prod

The prod root for the apis stack. Every `.tf` file here is a symlink into `infra/stacks/apis`, and `infra/dfo-dev/apis/README.md` documents that code. This directory holds the backend, the lock file, and the prod values in `env.auto.tfvars`.

## Apply order

Apply after `foundation`, `platform`, and `dcp`. Each commented line in `env.auto.tfvars` names the output it comes from: `datacommons_service_url` from `dcp`, and `psc_service_attachment_uri` and `dns_name` from `platform`. Uncomment them and copy the values in before the first plan, which fails with "No value for required variable" until they are set. The other cross-stack values follow from the namespace and are already filled in. `google_sql_provision_script.runtime_connect` grants CONNECT on databases `dcp` creates, so it fails if `dcp` has not applied. `platform`'s `allowed_consumer_projects` must list `prod-fin-observatory` for the PSC endpoint in `network.tf` to connect.

This stack creates `dfo-prod-caller-principal` and `dfo-prod-caller-hmac-key`, which the `ai` and `website` services mount, so it applies before them. The caller HMAC key replaced the `website` stack's `dfo-prod-website-caller-hmac-key`. The new key is a fresh value, so every visitor's `ip:` caller id changes once on the first apply that carries it. A rotation (a bump of `caller_hmac_key_version`) changes them again, and the website keeps the old key until it takes a new revision; "Caller HMAC key" in `infra/dfo-dev/apis/README.md` gives the steps, which here name `dfo-prod-website` and `--region europe-west1`.

It also creates `dfo-prod-share-import-principal`, which the `website` stack's share migration Job reads, so it applies before `website` for that secret too. The secret and the import route it gates are removed once prod's shares are migrated ("Share import principal" in `infra/dfo-dev/apis/README.md`).

## Hand-made prerequisites

- Secret Manager secrets `dfo-prod-apis-gemini-api-key` (the service's key, `data.google_secret_manager_secret.gemini` in `main.tf`) and `dfo-prod-search-catalogue-gemini-api-key` (the search catalogue Job's key, `data.google_secret_manager_secret.search_catalogue_gemini` in `search_catalogue.tf`). Each holds a key from its own AI Studio project on the DFO billing account, so the billing export attributes spend by caller. The data sources fail plan while a secret does not exist, and a secret with no version fails the revision or the Job run at apply.
- The `dfo-apis-deployer` service account, created by `foundation`.

## Handoff

`scripts/handoff.sh dfo-prod apis` sets every variable and secret dfo-apis's `production` GitHub Environment reads: the project, region and registry from `foundation`, the WIF secrets from `foundation`, and the service, worker and job names from this stack's outputs (`service_name`, `datasets_worker_service_name`, `datasets_migrate_job_name`, `datasets_maintenance_job_name`, `presentation_migrate_job_name`, `origin_catalogue_job_name`, `graph_release_job_name`, `search_catalogue_job_name`). `deploy_values` in `scripts/deploy-targets.sh` maps each name to its output.

## Alerts

Every alert policy in the stack notifies `Telemetry pipeline alerts: team`, the email channel the telemetry stack builds from the `alerts` object in `dfo-prod-telemetry-principals`. `env.auto.tfvars` names it in `alert_notification_channel`, so the telemetry stack must apply first and the addresses stay in its secret. `search_alert.tf`'s policy, `Search failing on the apis service`, opens when `dfo-prod-apis` logs three or more engine infrastructure errors, or answers three or more 5xx on `/api/search/resolve`, in 5 minutes. "Alert notifications" and "Search failure alert" in `infra/dfo-dev/apis/README.md` describe the lookup, both signals and the thresholds.

## Client-call metric

`client_calls.tf` declares `dfo-prod-client-calls`, the same log-based metric as dev's. `infra/dfo-dev/apis/README.md` describes it.

## Caller authentication

`env.auto.tfvars` sets `allow_unauthenticated = false` and an empty `invoker_members`, so the service refuses anonymous callers. The prod `website` and `ai` stacks grant their own runtime service accounts `roles/run.invoker` on `dfo-prod-apis`. Prod has no eval reader. `dcp_access.tf` grants `roles/run.invoker` on `dfo-prod-dc-datacommons-service` to the apis runtime account, the datasets worker, and the origin catalogue, graph release and search catalogue jobs, and `infra/dfo-prod/dcp/dfo.auto.tfvars` sets `datacommons_services_allow_unauthenticated_access = false`, so the Data Commons service is private. "Caller authentication" in `infra/dfo-dev/apis/README.md` describes the token each caller sends and how to add a caller. A person reaches the service through a local proxy that attaches their own token, which needs a project role that carries `run.routes.invoke`. In prod, `roles/editor` is held only by service accounts, so only `roles/owner` holders reach the service this way. A person who needs access otherwise needs a grant, which belongs in a principals secret, not a committed address.

The proxy command:

```bash
gcloud run services proxy dfo-prod-apis --region europe-west1 --project prod-fin-observatory --port 8083
```

If `allow_unauthenticated = false` cuts off a caller, restore public access by hand:

```bash
gcloud run services add-iam-policy-binding dfo-prod-apis --region europe-west1 --project prod-fin-observatory --member=allUsers --role=roles/run.invoker
```

The stack's IAM grants are additive `google_cloud_run_v2_service_iam_member` resources, so the next apply neither removes the manual binding nor reports it, and Terraform cannot see an `allUsers` binding made by hand. Remove it with `remove-iam-policy-binding` and the same arguments once the caller is fixed. The removal takes about two minutes to take effect. Setting `allow_unauthenticated = true` in `env.auto.tfvars` instead makes Terraform own the binding.
