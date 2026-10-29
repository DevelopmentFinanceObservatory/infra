# website — the DFO website

The GCP footprint for the DFO website: the Next.js app (frontend plus the Node-level proxy that fronts all API and MCP traffic), built by Ode in its own repo.

## Private network path to Postgres

This stack owns its private network path to the shared Cloud SQL instance in `dfo-dev/platform`, via the `consumer-psc-network` module. That path is a dedicated VPC, a `10.100.1.0/24` subnet, a reserved internal address, a Private Service Connect endpoint against the instance's service attachment, and a private DNS zone resolving the instance's PSC name to that address. The instance authorises this project on its side. This stack's endpoint is the other half, and neither one alone grants a connection.

The service attachment URI and the PSC DNS name are both copied in as literal values from the platform stack's own outputs rather than read through remote state, so this stack's plan never depends on the platform stack having applied. See `infra/modules/consumer-psc-network/README.md` for the reasoning and the full subnet range table.

## Cloud Run services

One `../../modules/cloud-run-service` instance, `dfo-dev-website-staging`. `dfo-website` deploys `staging` to it. Ownership follows the `ai` stack: this repo defines the service, that repo's CI owns the image.

It sits in `dev-fin-observatory`. That is not the staging environment stand-up tracked in #14 and #19, which covers a separate `infra/dfo-staging` root with its own state and applier. A service in an existing stack needs none of it.

The service's env vars carry the host, database name, runtime user and instance connection name for its own database. No password. The runtime user authenticates as the service's own identity over IAM auth. The service carries direct VPC egress onto `module.psc_network`'s subnet, the private path to the tenant database below.

The service has no domain mapping, so it is reachable only at its generated `run.app` URL. `allow_unauthenticated` is true because the service is the public website. `google_cloud_run_v2_service_iam_member.website_apis_invoker` in `main.tf` grants its runtime account `roles/run.invoker` on the apis service, named by `var.apis_service_name`, a plain value copied from the `apis` stack's `service_name` output. The app sends an ID token as that account on its calls to the apis service; see "Caller authentication" in the `apis` stack's README.

## Studio proxy and auth env

The service (`module.website_service`, named `dfo-dev-website-staging` from `var.namespace` and `var.tier`) carries the env vars and secrets its `/api/studio/*` proxy and better-auth session handling need, per the `dfo-website` deploy README's runtime env contract.

`STUDIO_API_BASE` is the `dfo-dev-ai` Cloud Run URL the proxy forwards to, set from `var.studio_api_base`. That value is copied from the `ai` stack's `service_url` output rather than read through remote state, the same rationale `var.dfo_apis_url` records in the `ai` stack.

`STUDIO_TOKEN` is the bearer token the proxy sends to the harness. The secret belongs to the `ai` stack, created in `infra/dfo-dev/ai/studio_token.tf`. This stack reads it through a plain `data "google_secret_manager_secret"` source, the same cross-stack pattern `ai/main.tf` and `apis/main.tf` use for `dfo-dev-gemini-api-key`. It isn't version-pinned, since the `ai` stack owns rotation and this stack holds no version resource of its own to pin against. Rotating it in the `ai` stack deletes the old version, and running website instances keep the value they started with, so after the `ai` apply roll the staging service onto a new revision by re-running dfo-website's `deploy.yml` for the `staging` branch. Pinning a version here would not close that gap: the pinned version is the one the rotation deletes.

`BETTER_AUTH_SECRET` is generated here, in `auth_secret.tf`, with the same ephemeral-`random_password`-plus-write-only-version-plus-counter shape as `studio_token.tf` in the `ai` stack. It's stored as `dfo-dev-website-staging-better-auth-secret` and mounted pinned to its version, so warm and new instances can never disagree on the signing key during a rotation. Rotation means bumping `website_better_auth_secret_version` in `auth_secret.tf`. The app reads a single key, so a rotation signs everyone out and restarts any sign-in in progress. Better Auth's `BETTER_AUTH_SECRETS` supports an overlap period, which would need an app change first.

`CALLER_HMAC_KEY` is the key the `/mcp` proxy HMACs the client IP with to form the `x-dfo-caller` header it sends to the harness and to `dfo-apis`. The `apis` stack creates and rotates it in `caller_hmac_key.tf`, as `dfo-dev-caller-hmac-key`, and mounts it on `dfo-dev-apis` as `DFO_CALLER_HMAC_KEY`, so both services name a client by one digest. This stack reads it through `var.caller_hmac_key_secret_id`, the same cross-stack pattern as `var.live_refresh_principal_secret_id` below, and the mount reads `latest`. Every rotation changes every visitor's caller identity. That identity is the `ip:` caller in the combined MCP server's request log lines and the frame `writer` that data-mcp and analysis-mcp record on stored frames, so both show a new value for the same visitor after a rotation. The apply that moved the key from this stack to `apis` changed it once in the same way, and destroyed the old `dfo-dev-website-staging-caller-hmac-key`, which needs the `allow-destroy` label on its pull request. "Caller HMAC key" in the `apis` stack README gives the rotation steps.

`TRUSTED_PROXY_HOPS` is set from `var.trusted_proxy_hops` and omitted while that is null. The app's default of 0 takes the rightmost `X-Forwarded-For` entry, which is the one Google's front end appends on a bare `run.app` URL. Behind Cloudflare and the Google load balancer the header reads `client, cloudflare-edge, lb`, so the client sits 2 hops from the right and the variable takes 2.

`MCP_API_TOKEN` is the bearer token the `/mcp` proxy sends to the harness, whose MCP mounts (`/mcp/data`, `/mcp/analysis`, `/mcp/presentation`) answer `401` without it. Visitors reach `/mcp` anonymously, so the proxy supplies the token. The secret is `dfo-dev-mcp-api-token`, created in `infra/dfo-dev/ai/mcp_token.tf`. This stack reads it through a `data "google_secret_manager_secret"` source, the same pattern as `STUDIO_TOKEN`, and the `cloud-run-service` module grants the website's runtime service account `secretAccessor` on it. The mount reads `latest`, since the `ai` stack owns rotation. After a rotation there (a bump of `mcp_api_token_version`), running website instances keep the old token and the harness refuses it, so roll the staging service onto a new revision as the `STUDIO_TOKEN` paragraph describes.

`BETTER_AUTH_URL` is the staging service's own public origin, set from `var.website_url`. A module self-reference to `module.website_service.service_url` would cycle, so this value is the same `run.app` URL copied in as a literal instead.

`var.ingress` (default `INGRESS_TRAFFIC_ALL`) is passed to the `cloud-run-service` module. `INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER` makes the `run.app` URL refuse requests that do not arrive through the global external Application Load Balancer. `allow_unauthenticated` stays true under it, because the load balancer's serverless NEG calls Cloud Run without an identity token.

`SEARCH_API_BASE` is the `dfo-dev-apis` Cloud Run URL the search, datasets and graph proxies forward to, set from `var.search_api_base` and copied from the `apis` stack's `service_url` output. The app refuses to start in production without it.

## Sign-in providers

Sign-in is social-only, so `/login` offers exactly the providers named in `local.sign_in_providers` (`sign_in_providers.tf`): Google, GitHub and Microsoft. Each provider mounts `<PROVIDER>_CLIENT_ID` and `<PROVIDER>_CLIENT_SECRET` from the hand-created secrets `dfo-dev-website-staging-<provider>-client-id` and `dfo-dev-website-staging-<provider>-client-secret`. The app offers a provider only when both are set, so each provider mounts as a pair. The stack reads the secrets through `data` sources, so a listed provider whose secrets are missing fails `plan`, and a PR cannot merge into a state where the service can't start new revisions.

To add a provider, register its OAuth client, create and fill both secrets, then add its name to the list. The `read -rs` prompts keep the values off the screen and out of shell history:

```
gcloud secrets create dfo-dev-website-staging-<provider>-client-id --project dev-fin-observatory --replication-policy automatic
gcloud secrets create dfo-dev-website-staging-<provider>-client-secret --project dev-fin-observatory --replication-policy automatic
read -rs ID; printf '%s' "$ID" | gcloud secrets versions add dfo-dev-website-staging-<provider>-client-id --project dev-fin-observatory --data-file=-
read -rs SECRET; printf '%s' "$SECRET" | gcloud secrets versions add dfo-dev-website-staging-<provider>-client-secret --project dev-fin-observatory --data-file=-
```

Fill both secrets before the PR merges. A secret with no version passes `plan`, and the new revision then fails to start.

Each provider's callback URL is `https://dfo-dev-website-staging-zms5lj4zhq-nn.a.run.app/api/auth/callback/<provider>`.

- Google: a Web application OAuth client under Google Auth Platform, Clients, in `dev-fin-observatory`. The app requests only `openid`, `email` and `profile`, so any Google account can sign in while the consent screen's publishing status is Testing.
- GitHub: the OAuth App "Development Finance Observatory (staging)", owned by the ONEcampaign organisation. The app requests `read:user` and `user:email`.
- Microsoft: the Entra app registration "Development Finance Observatory" (client ID `07e24f61-0ba9-44ca-9317-939ff95e73e7`) in ONE's tenant, which ONE's IT team administers. It accepts work, school and personal accounts, matching the app's `tenantId: 'common'`, and registers both the staging and `developmentfinance.org` callbacks. The mounted secret is the credential labelled "Staging", which expires on 27 September 2028; rotating it before then needs IT or an app owner.

Rotating a client is a new version on each secret. The mounts track `latest`, but running instances keep the value they started with, so roll the service onto a new revision afterwards (see `STUDIO_TOKEN` above).

## PostHog telemetry

`POSTHOG_KEY` and `POSTHOG_HOST` point the app's usage telemetry (the curated event list the telemetry plan describes; events, not pageview autocapture) at the DFO project on PostHog Cloud EU. The key is a project API key, a public write-only token that PostHog designs to ship in client-side JavaScript, so it is a plain env var set in `env.auto.tfvars`, not a Secret Manager entry; anyone holding it can send events but read nothing. The org and project are managed in the PostHog UI (org owned by ONE/Ode, EU region, free tier at setup time), not by Terraform. The free tier allows one project, so staging and production share it and every event carries an `environment` property; rotating the key (PostHog project settings) is a `posthog_key` change in each environment's `env.auto.tfvars` plus the usual new-revision roll.

## Datasets pin principal

`DFO_PRINCIPAL` is the bearer value the app sends as the `x-dfo-principal` header on its server-side `POST /api/datasets/{spec_id}/{content_version}/pin` call, in `createSearchShare`'s snapshot path (`src/lib/search/searchShare.ts` in `dfo-website`). Unset or refused, that call fails and the module catches the error: the snapshot share still saves, unpinned, so a stale or missing value fails silently rather than surfacing to the visitor.

The secret is created and rotated in the `apis` stack, as `dfo-dev-datasets-pin-principal`, and is this door's only value: the datasets publish door reads a separate secret. This stack reads it through `var.datasets_pin_principal_secret_id`, a plain value copied from the `apis` stack's secret id, the same cross-stack pattern `var.datasets_first_party_principal_secret_id` in the `ai` stack records — not a `data "google_secret_manager_secret"` source like `STUDIO_TOKEN` above, because a data source resolves against live state at plan time, so this stack's plan would fail whenever the `apis` stack had not yet created the secret.

The mount reads `latest` rather than a pinned version: this stack holds no version resource of its own to pin against, and the `apis` stack owns rotation. A `terraform apply` here is a no-op after a rotation in `apis` — this stack's own configuration hasn't changed — so the value only reaches a running instance on a new revision: a `dfo-website` deploy of the `staging` branch, or `gcloud run services update dfo-dev-website-staging --region northamerica-northeast1 --update-labels=pin-principal-rotated=<n>` to force one without a new image.

Any visitor can reach this call: `allow_unauthenticated = true` above means nobody has to sign in to create a search share, and a snapshot share's capture step mints and pins on that visitor's behalf. The value is a shared bearer, the same exposure the `apis` stack's README records for the publish door: while the apis service admits anonymous callers, anyone who learns it can pin the same as this service can, and pinning has no reverse route. Once the apis service drops `allow_unauthenticated`, only identities holding `roles/run.invoker` on it reach the pin door at all, and this value becomes a second check.

## Live-refresh principal

`LIVE_REFRESH_PRINCIPAL` is the bearer value the app sends server-side when a live Studio share opens. It goes in the `x-dfo-principal` header on the `dfo-apis` frame refresh and Presentation render calls, and in `Authorization: Bearer` on the `dfo-ai` `POST /api/studio/refresh` call. It never reaches the browser. Unset or empty, the app offers no Live Data option when a visitor shares a canvas or card.

The secret is created and rotated in the `apis` stack, as `dfo-dev-live-refresh-principal`. This stack reads it through `var.live_refresh_principal_secret_id`, a plain value copied from that stack's secret id, the same cross-stack pattern as `var.datasets_pin_principal_secret_id` above. When both stacks change in one merge, `apply.yml` applies `apis` first, since it lists `apis` as a producer stack.

The mount reads `latest`, so the value reaches a running instance only on a new revision after a rotation in `apis`. A `dfo-website` deploy of the `staging` branch creates one, and `gcloud run services update dfo-dev-website-staging --region northamerica-northeast1 --update-labels=live-refresh-principal-rotated=<n>` forces one without a new image.

## Caller principal

`DFO_CALLER_PRINCIPAL` is the value the app sends as `x-dfo-caller-principal` on every `dfo-apis` call, so `dfo-apis` trusts the `x-dfo-caller` digest beside it. Unset, the app sends neither header. The secret is created and rotated in the `apis` stack, as `dfo-dev-caller-principal`, and this stack reads it through `var.caller_principal_secret_id`, the same cross-stack pattern as `var.live_refresh_principal_secret_id` above. The mount reads `latest`, so a rotation reaches a running instance only on a new revision, as for the live-refresh principal.

## Feedback Slack webhook

`FEEDBACK_SLACK_WEBHOOK_URL` is the Slack incoming webhook the app's `/api/feedback` endpoint posts each submission to. Slack issues the URL, so unlike `BETTER_AUTH_SECRET` it can't be generated here: `feedback_webhook.tf` owns the secret container (`dfo-dev-website-staging-feedback-slack-webhook`) and the mount, and the URL itself is added out-of-band as a version. The mount tracks `latest` (a pinned version would point at whatever Terraform knew about, which is never the real URL), and a placeholder first version with the literal `disabled` guarantees the mount always resolves, since Cloud Run refuses to start a revision whose secret env var can't be read. The app treats any value that isn't a Slack webhook URL as "notifications off", so the placeholder is inert.

Adding or rotating the URL (webhook leaked, channel changed, Slack app reinstalled) is one command for anyone with `secretmanager.versions.add` on the project, plus a redeploy so instances pick it up:

```
printf '%s' 'https://hooks.slack.com/services/…' | gcloud secrets versions add \
  dfo-dev-website-staging-feedback-slack-webhook \
  --project dev-fin-observatory --data-file=-
```

`printf` rather than `echo` keeps a trailing newline out of the stored value, and passing the URL via stdin keeps it out of shell history less than an argument would, but not out of this machine's history entirely; run it from a shell with history off if that matters. Running website instances keep the value they started with, so after adding a version roll the service onto a new revision by re-running dfo-website's `deploy.yml` for the `staging` branch, the same gap and fix the `STUDIO_TOKEN` paragraph above describes.

## Email sign-in

`/login` also offers sign-in by emailed code, but only when the app has all four settings: a mail transport (`SES_ROLE_ARN`, `SES_REGION` and `SES_TOKEN_AUDIENCE`), `AUTH_EMAIL_FROM`, `TURNSTILE_SITE_KEY` and `TURNSTILE_SECRET_KEY`. `email_sign_in.tf` sets `AUTH_EMAIL_FROM` to `DFO Studio <studio@developmentfinance.org>`, the one address the SES role's policy lets the service send as, compared case-sensitively. The SES values come from the `ses` object in `env.auto.tfvars`, the Turnstile site key from `turnstile_site_key`, which defaults to null, and the Turnstile secret key from a secret. The app trims every value and treats a blank one as unset, and a transport missing any of the three SES values counts as no transport, so email sign-in stays off until every value exists.

Turnstile guards the form. The widget is "DFO website staging" in the ONE Campaign Cloudflare account (Application security, Turnstile), for this service's run.app host, and `env.auto.tfvars` holds its site key as `turnstile_site_key`. The site key is public, since the login page renders it. A new hostname for the service must be added to the widget, or the check fails there. The secret key is mounted from `dfo-dev-website-staging-turnstile-secret-key`, whose container the stack creates with a placeholder first version holding a single space. Cloud Run refuses a revision whose secret env var can't be read, and the mount tracks `latest`, so the secret must always have a version. A single space reads as blank, so the placeholder keeps email sign-in off whatever else is set. Add the real key as a new version, which then becomes `latest`:

```
read -rs KEY; printf '%s' "$KEY" | gcloud secrets versions add dfo-dev-website-staging-turnstile-secret-key --project dev-fin-observatory --data-file=-
```

Mail goes out through the Amazon SES API in ONE's AWS account (`961128127831`, `us-east-1`), whose infrastructure team owns the AWS side. The service trades its runtime service account's Google ID token for temporary AWS credentials, so no AWS key is stored. The role `development-finance-observatory-ses-sender-staging` trusts only `dfo-dev-website-staging-run@dev-fin-observatory.iam.gserviceaccount.com`, and only with the token audience `development-finance-observatory-staging`, which `env.auto.tfvars` sets as `ses.token_audience`. Staging sends real mail from the production address, so sign in there with test inboxes only. Every ONE service shares the account's limit of 20 sends a second, and bounces count against ONE's whole sending reputation. Google ID tokens name a service account by its unique ID, so recreating the runtime service account breaks sending until ONE updates the role's trust policy. Read the ID with:

```
gcloud iam service-accounts describe dfo-dev-website-staging-run@dev-fin-observatory.iam.gserviceaccount.com --project dev-fin-observatory --format='value(uniqueId)'
```

Running instances keep the values they started with. A change to `turnstile_site_key` or `ses` reaches the service through `terraform apply`, which creates a new revision. A new secret version needs a manual roll onto a new revision:

```
gh workflow run deploy.yml -R DevelopmentFinanceObservatory/website --ref dev
```

## Tenant databases

`database.tf` holds the website's database on the shared Cloud SQL instance from the `platform` stack: accounts, saved views, share links. ADK agent sessions live in the ai stack's own tenant database instead (#155), because ADK creates its schema over whatever connection it gets and the website runtime should hold DML only.

The website's database is `website-staging`. Its runtime user holds CONNECT only on that database and no DDL.

Schema management runs through an IAM service account, the migrator: a Job's target database is only an env var its container reads, so the migrator identity is what actually keeps the Job's DDL scoped to the `website-staging` database. The migrator carries no password and nothing sits in Secret Manager. Terraform grants it CONNECT and CREATE on only its own database, plus CREATE and USAGE on that database's public schema, and grants that same schema USAGE to the runtime user too. Nothing else is granted here. USAGE lives in Terraform rather than the app's migration because a migrator-issued `GRANT USAGE ON SCHEMA public` is a no-op (the migrator holds CREATE, not ownership or grant option), so only the applier can actually grant it. The app's `db/migrations/0000_bootstrap_grants.sql` migration issues `ALTER DEFAULT PRIVILEGES` in that schema, which is what gives the runtime user DML on the tables its migrator creates, plus one global default-privileges revoke (no schema clause, by design) that strips PUBLIC's EXECUTE on every routine the migrator ever creates. Runtime and migrator account IDs are operationally fixed. Renaming the runtime account strands its table and sequence ACLs and future default grants. Renaming the migrator strands object ownership and its `pg_default_acl` records. Account rotation is deferred until Cloud SQL's required memberships and administrator path have been live-tested. A Cloud Run Job applies the migrations, driven from the website app's deploy pipeline. Connection details for the runtime user and the migrator are in the outputs. The database resources lean on `sqladmin.googleapis.com`, enabled project-wide by `platform`. This stack declares only the `compute` and `dns` APIs it consumes directly, the same borrowing `apis` records.

## Event export

`event_export.tf` builds the exporter that copies the website database's `event` table into the BigQuery dataset `website_export` (EU multi-region) every hour, as dfo-website's `node dist/export-events.cjs`. Visitor and user ids leave Postgres only as HMAC-SHA256 under `EXPORT_ID_HMAC_KEY`, and no free text leaves at all. The job creates its own `event` table; Terraform owns the dataset and its grants only.

Every tier gets the exporter's identity and database access, because dfo-website's migration that runs `GRANT SELECT ON "event" TO website_export_reader` runs in every tier. The identity is the service account `dfo-dev-website-stg-export` (`dfo-prod-website-export` in prod), its IAM database user, and the same `roles/cloudsql.client` and login-only pair the runtime user holds. Two provision scripts create the NOLOGIN role `website_export_reader` if it is absent, grant it CONNECT on the website database and USAGE on its public schema, and make the exporter user a member. Every privilege sits on the role, so the exporter can read exactly what dfo-website's migrations grant that role. Postgres roles are instance-wide, and each instance hosts one website database, so one role name serves every tier.

Only `infra/dfo-prod/website/env.auto.tfvars` sets `event_export_enabled = true`. In prod it adds:

- the `website_export` dataset, with `WRITER` for the exporter through `google_bigquery_dataset_access` and no `access` blocks, which would drop the grants such resources add here and in the telemetry stack;
- `roles/bigquery.jobUser` on the project for the exporter;
- the secret `dfo-prod-website-export-hmac-key`, generated like the auth secret and mounted pinned to its version;
- the Job `dfo-prod-website-export`, on the service's PSC network with the service's `WEBSITE_DB_*` settings and the exporter as `WEBSITE_DB_USER`, plus `EXPORT_BQ_PROJECT`, `EXPORT_BQ_DATASET` and `EXPORT_ID_HMAC_KEY`;
- an hourly Cloud Scheduler trigger whose own service account holds `roles/run.invoker` on the Job alone;
- `roles/run.developer` on the Job and `roles/iam.serviceAccountUser` on the exporter for the website deployer.

The Job bootstraps from `gcr.io/cloudrun/hello`, which has no `node`, so an execution before dfo-website's deploy moves the image fails. The deploy finds the Job through `EXPORT_JOB_WEBSITE`, which `scripts/handoff.sh dfo-prod website` writes from the `export_job_name` output. Executions have a 30-minute timeout and no retry, since the next hourly run replaces the same days.

Rotating the hashing key means bumping `website_export_hmac_key_version`. Every hashed id then changes, and only the days the next run reloads carry the new hashes, so a rotation also needs the `event` table dropped for a full reload.

## Share migration

`share_migrate_job.tf` builds the Job `dfo-dev-website-staging-share-migrate`, which runs dfo-website's `node dist/migrate-shares.cjs` once to move the website's `share` rows into dfo-apis's Presentation store. For each owned share it mints or reuses the owner's write token in `share_token` and calls dfo-apis's share import route with the token's SHA-256. Guest shares go with no digest. A share it cannot import prints `share <id>: <code> <detail>` and the run carries on, then exits 1. A re-run reuses stored tokens and dfo-apis answers an imported share as unchanged, so running it again after a fix is safe.

The Job runs as the service's runtime account with the service's `WEBSITE_DB_*` settings, since it writes `share_token` with the same DML the service holds. It reads the apis base URL from `SEARCH_API_BASE` and calls dfo-apis with an ID token minted as that account, which `website_apis_invoker` already allows. `PRESENTATION_SHARE_IMPORT_PRINCIPAL` reads `latest` of the `apis` stack's `dfo-dev-share-import-principal` through `var.share_import_principal_secret_id`, and the runtime account holds `roles/secretmanager.secretAccessor` on that secret alone. The Job uses the service's PSC network, a one-hour timeout and no retry. The deployer holds `roles/run.developer` on it.

The Job bootstraps from `gcr.io/cloudrun/hello`, which has no `node`, so an execution before dfo-website's deploy moves the image fails. The deploy finds the Job through `SHARE_MIGRATE_JOB_WEBSITE`, which `scripts/handoff.sh dfo-dev website` writes from the `share_migrate_job_name` output. Once dfo-apis serves the import route and the deploy has moved the image, run:

```bash
gcloud run jobs execute dfo-dev-website-staging-share-migrate \
  --region=northamerica-northeast1 --project=dev-fin-observatory --wait
```

On exit 1, read the `share <id>:` lines in the execution's logs, fix the cause, and run it again. Then run `normalise-recipes` on `dfo-dev-datasets-maintenance` (see the `apis` stack's README). The Job, the import route and its principal are removed once prod's shares are migrated.
