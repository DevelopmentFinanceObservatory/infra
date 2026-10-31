# apis — the DFO Search, Datasets and Graph APIs

One Cloud Run service, `dfo-dev-apis`, running the `dfo-apis` repo's image. It serves three APIs. The Search API resolves natural-language data requests against a Data Commons graph. The Datasets API serves dataset specs and artifacts, and this stack grants it the storage, database and private-network access it needs. The Graph API reads DCP (Data Commons Platform) directly and holds no persistence seam of its own, unlike Datasets.

The search engine also runs today as a passenger inside the Data Commons container in the `dcp` stack (see that stack's `dfo.tf`). This service is a second, independently-scaled place to reach it, not a replacement for that one.

The service is defined via the reusable `../../modules/cloud-run-service` module (see that module's README) — a dedicated runtime service account, scaling config, and env vars/secrets.

## Model credentials

The service reads `GEMINI_API_KEY` from the process environment. It warm-loads its Gemini client at startup, so a missing or invalid key fails the revision at startup. This stack wires that env var to the Secret Manager secret `var.gemini_api_key_secret_id` names. Dev sets `dfo-dev-gemini-api-key`, the secret the `ai` stack and the DFO prototype app on the Data Commons service (`infra/stacks/dcp/dfo.tf`) also use. Prod gives each caller its own secret, holding a key from its own AI Studio project, so the billing export attributes Gemini spend by caller. Terraform does not manage that secret. This stack references it through a `data "google_secret_manager_secret"` source. The runtime service account is granted `roles/secretmanager.secretAccessor` scoped to only that one secret.

## Graph and engine configuration

`SEARCH_GRAPH_BASE` and `SEARCH_ENGINE_MODEL` are declared as stack variables (see `variables.tf`) rather than inlined, so they're visible and overridable in one place.

`SEARCH_GRAPH_BASE` points at the `dfo-dev` Data Commons service, the same graph the Datasets variables below target. It sits behind no WAF, so `SEARCH_GRAPH_TOKEN` stays unset, and the service reaches it with the ID token "Caller authentication" describes. It carries the `sdg` namespace but none of ONE's own imports, so the query families that depend on those resolve to `no_data`.

Moving this to `datacommons.one.org` takes more than a new value. That graph blocks callers whose requests carry no browser user agent, and the engine's SDMX client sends none, so the development-finance family gets a 502 `upstream_error` there.

`SEARCH_ENGINE_MODEL` names a dated Gemini release. The `gemini-flash-lite-latest` alias floats, so the model behind a running revision can change with no image or revision to record it, and frozen evaluation baselines stop being reproducible.

dfo-apis reads the DC service's serving revision as its graph-generation cache token, so each ingestion, which restarts DCP onto a new revision, clears every graph-derived cache. `graph_generation_access.tf` grants the apis runtime service account and the datasets worker's `roles/run.viewer` on the DC service so each can read that revision through the Cloud Run Admin API, and `DFO_GRAPH_GENERATION_SERVICE` carries the service's full resource name on the apis service (`main.tf`) and the worker (`datasets_worker.tf`). All three read `var.datacommons_service_name`. The `datasets-maintenance` Job builds no graph cache and sets neither this variable nor `GOOGLE_CLOUD_PROJECT`; the worker and the apis service set `GOOGLE_CLOUD_PROJECT` so their log lines carry Cloud Logging's trace field.

The Datasets API reads its graph endpoint from `DATASETS_GRAPH_BASE_URL` and its SDMX endpoint from `DATASETS_SDMX_BASE_URL`, both pointed at the `dfo-dev` Data Commons service. Both carry the API root down to `/core/api`, since the Datasets API's clients append `/v2/node` and `/sdmx/v3/...` straight onto them. `SEARCH_GRAPH_BASE` takes a bare host instead, because the search client appends `/core/api/v2` itself. On the dev graph `POST /core/api/v2/node` answers 200 and `POST /v2/node` answers 405, so a value in the wrong shape fails every call. Collapsing the three variables into one breaks a client at whichever end loses its suffix.

The Graph API reads its DCP endpoint from `GRAPH_DCP_BASE_URL`, pointed at the same `dfo-dev` Data Commons service and carrying the same `/core/api` root as the two Datasets variables above, since `materialise.graph.LiveGraphReader` appends `/v2/node` and `/v2/observation` onto it the same way the Datasets clients append their own paths.

`DFO_CORS_ORIGINS` is a comma-separated browser-origin allowlist applied platform-wide across every surface this service mounts, and starts empty: empty means no CORS headers are added, and a wildcard is never used. It gains the Data Commons service's origin once the in-container engine is retired and that service's browser-side prototypes start calling this service cross-origin.

## Ownership split with the `dfo-apis` repo

This stack owns the service _definition_; the `dfo-apis` repo's CI owns the _image_, updating it with image-only `gcloud run services update` calls. The module's `lifecycle.ignore_changes` on the container image is what makes that work without every `apply` reverting to the bootstrap placeholder image (`gcr.io/cloudrun/hello`) — see the module README for details.

## Datasets API access

`datasets_access.tf` grants the runtime service account (`module.apis_service.runtime_service_account_email`) the access the Datasets API needs against storage and the database it does not own: `roles/storage.objectCreator` and `roles/storage.objectViewer` on both the working and pinned buckets, `roles/iam.serviceAccountTokenCreator` on itself for V4 signed URLs, `roles/cloudsql.client` and `roles/cloudsql.instanceUser` on the project, and a `CLOUD_IAM_SERVICE_ACCOUNT` Cloud SQL user on the shared Postgres instance. The buckets, the database, and the garbage-collection identity that can delete from the pinned bucket are declared in the `dcp` stack — storage and the database are unaffected by which service runs against them, but every one of these grants names _this_ stack's runtime identity, so it lives here.

`roles/cloudsql.client` and `roles/cloudsql.instanceUser` are project-scoped rather than narrower: the instance authorises per project (platform's `allowed_consumer_projects`), not per consumer, so there is no finer grain to grant them at while every stack here shares `dev-fin-observatory`.

The bucket names, the Cloud SQL instance name, and the instance connection name reach this stack as plain values in `env.auto.tfvars`, copied from the `dcp` and `platform` stacks' own outputs rather than read via `terraform_remote_state`, the same rationale those stacks record for their own cross-stack values, so a plan here never depends on either having applied.

`network.tf` gives the service the private network path those grants assume: an instantiation of `../../modules/consumer-psc-network` on `10.100.3.0/24` (see that module's README for the full range table), and direct VPC egress from the Cloud Run service onto that subnet, via the `cloud-run-service` module's `vpc_access` input (see that module's README).

A migration runner for the Datasets schema reads the runtime username from this stack's `datasets_runtime_db_user` output. The database name and the migrator password secret stay in the `dcp` stack's outputs, next to the database they describe.

`google_sql_provision_script.runtime_connect` in `datasets_access.tf` grants the runtime user CONNECT on the `datasets` and `presentation` databases. The `dcp` stack creates both and revokes PUBLIC's default CONNECT on each, and an explicit grant survives that revoke. The grant sits here, next to the role it names, so `dcp` applies before this stack on an empty project. The two database names come from `dcp`'s outputs through `env.auto.tfvars`.

**Orphaned Postgres role.** These grants replace ones on `dfo-dev-dc-srvs-sa`, the serving account the Data Commons stack module creates — see the `dcp` stack's `dfo.README.md` for the operator step that drops that role from the shared instance by hand.

## Datasets API environment

`DATASETS_ARTIFACT_BUCKET_WORKING` and `DATASETS_ARTIFACT_BUCKET_PINNED` read the same `env.auto.tfvars` values the bucket grants above target, so the bucket the app writes to and the bucket the runtime identity can write to stay the same one.

`DATASETS_GRAPH_TOKEN` is unset. The graph sits behind no WAF, so there is no WAF-skip secret to carry. `DATASETS_SYNC_CEILING_ROWS` is unset too, leaving the app's own default of 50000, which it republishes on `GET /api/datasets/capabilities` with a flag marking it provisional.

`DATASET_STORE_INSTANCE_CONNECTION_NAME` and `DATASET_STORE_RUNTIME_DB_USER` give the app its runtime database path. The connection name routes the session through the Cloud SQL Python Connector rather than plain TCP, and the connector mints an IAM access token for the runtime service account, so `DATASET_STORE_RUNTIME_DB_PASSWORD` stays unset and there is no password to store or rotate. The username reads `google_sql_user.datasets_runtime` directly, the same resource that creates the Postgres role, so the name the app logs in as and the role that exists on the instance are one value. `DATASET_STORE_DATABASE` stays unset, leaving the app's own default of `datasets`, the database the `dcp` stack creates.

The connector reaches `sqladmin.googleapis.com` over the service's ordinary egress. `PRIVATE_RANGES_ONLY` sends only RFC 1918 destinations down the PSC subnet, and the Admin API answers on a public address, so that call takes the same route the Gemini client already takes.

`datasets_migrate_job.tf` deliberately omits the connection name and reaches the PSC endpoint address over plain TCP instead. The migrator is a `BUILT_IN` password user, so the connector buys it nothing.

The surface mounts. `DFO_DATASETS_SURFACE` reads `"true"` (see `variables.tf`), so the app imports its datasets package at startup and reads all of these variables to build its live registry. `GET /api/datasets/healthz` answering 200 proves only that the surface mounted: that route is static, declared in `datasets_api/doors/meta.py` with no live dependency, so it answers 200 whether or not the database path works. The check that actually exercises the runtime user's grants on the `datasets` schema is the first real `/api/datasets/*` request that reaches Postgres.

The connector path itself works. A Cloud Run Job running `python -m dataset_store.smoke` as the runtime service account, on this stack's PSC subnet with the same egress setting the service uses, opened an IAM-authenticated session to the `datasets` database and ran `SELECT 1` inside a transaction. That covers the identity, the network route, and the grants. The serving revision itself has run none of it, and `SELECT 1` reads no table, so the runtime user's privileges on the `datasets` schema remain untested.

## Public site origin

`DFO_PUBLIC_SITE_URL` is the origin of the public website, which also proxies `/api/*` to this service. dfo-apis builds every download bundle link on it, and a service that builds the datasets or presentation settings refuses to start without it. `main.tf` sets it on the apis service and `datasets_worker.tf` on the worker, both from `var.dfo_public_site_url`. `env.auto.tfvars` sets it to the staging website's Cloud Run URL, the `website` stack's `staging_service_url` output. The migration jobs and the catalogue jobs never build those settings and do not carry it. `DFO_SITE_DATASET_LINKS` is `true` on both, so bundles of a definition the website can replay print its `/data?spec=&v=` page. Apply this stack before rolling out a dfo-apis release that reads the variable.

## Graph API environment

The Graph surface reads DCP directly and holds no persistence seam of its own, so unlike Datasets it needs no bucket grants, no database access and no migration job.

`GRAPH_DCP_BASE_URL` (see "Graph and engine configuration" above for the URL shape) is the one variable its own lifespan requires once `DFO_GRAPH_SURFACE` is on, and there is no safe default for it. A revision carrying the flag on with this variable unset fails to serve any request at all, on any surface, not just `/api/graph/*`, because the lifespan runs before the first request lands. This stack always sets both together, so that failure mode does not arise here, but the two variables have to keep changing as a pair.

`GRAPH_DCP_TOKEN` is unset. It is the same WAF-skip secret Search's `SEARCH_GRAPH_TOKEN` and Datasets' `DATASETS_GRAPH_TOKEN` send to their own graph endpoints, and neither of those is set on this service: the graph sits behind no WAF, so there is no secret to carry.

The surface mounts. `DFO_GRAPH_SURFACE` reads `"true"` (see `variables.tf`), so the app mounts `GET /api/graph/healthz`, `POST /api/graph/resolve`, and `GET /api/graph/node/{dcid}` alongside Search and Datasets.

## Skills API environment

The Skills surface reads the same graph the Search surface reads, through Search's graph client and skills index, so it needs no bucket grants, database access, migration job, or variable beyond its flag. `DFO_SKILLS_SURFACE` reads `"true"` (see `variables.tf`), so the app mounts the Skills API at `/api/skills` alongside the other surfaces.

## Decisions on record

**`min_instances = 1`.** One warm instance avoids the user-visible wait while the engine loads its Gemini client. The idle instance incurs baseline billing.

**No startup probe.** The `cloud-run-service` module declares none because the bootstrap placeholder image (`gcr.io/cloudrun/hello`) serves no health path. A probe checking for it would fail the very first `apply`, before any real image exists. The real `dfo-apis` image serves `GET /api/search/healthz`; configuring a startup probe against that path requires the real image to be running, so it belongs in a later change when the image deployment workflow is in place.

**Caller authentication at Cloud Run IAM.** The service keeps the module's default `INGRESS_TRAFFIC_ALL`, since its callers reach it at the public `run.app` URL, and Cloud Run IAM decides which callers get through. See "Caller authentication" below.

## Caller authentication

Cloud Run IAM is the service's only identity boundary. Each `roles/run.invoker` grant on the service sits in the stack that owns the identity it names:

- `allow_unauthenticated`, set in this stack's `env.auto.tfvars`, grants it to `allUsers`. It is `false` in dfo-dev and dfo-prod, so the service refuses anonymous callers.
- `invoker_members`, set in the same file, grants it to each listed identity. It holds principals no stack owns and is empty in both environments.
- The `website` and `ai` stacks grant it to their own runtime service accounts, as `google_cloud_run_v2_service_iam_member.website_apis_invoker` in `infra/stacks/website/main.tf` and `google_cloud_run_v2_service_iam_member.ai_apis_invoker` in `infra/stacks/ai/main.tf`. Each names this service through its `apis_service_name` variable, copied from this stack's `service_name` output. `apply.yml` applies this stack first, so the service exists before either grant, and this stack names no account another stack creates.
- In dfo-dev, `eval_reader.tf` grants it to `dfo-dev-apis-eval-reader` and `sdk_e2e.tf` to `dfo-dev-sdk-e2e`, each by resource reference. The first serves the apis repository's eval jobs. The second serves the sdk repository's end-to-end workflow, and only a run on that repository's `refs/heads/main` can mint it, matched on `attribute.repo_ref`. The sdk repository has an entry in the `foundation` stack's `github_repositories` so the shared pool admits its tokens, and `dfo_sdk_repository_id` here copies that entry's id.

A caller authenticates with a Google ID token minted as one of those identities, with the service URL it calls as the audience (origin only, no path), sent as `X-Serverless-Authorization: Bearer <token>`. Cloud Run checks that header in preference to `Authorization` and strips the signature before the container sees it, so it never collides with the `Authorization` header the website proxy passes through or the ai bearer. Cloud Run refuses a request without a valid token from a granted identity.

Publish, pin and the refresh routes also compare an `x-dfo-principal` value (the three principal sections below), so a direct caller needs that value as well. Public users keep anonymous dataset creation through the website's `/api/v1/datasets` proxy, which the edge rate-limits in prod. `DFO_CORS_ORIGINS` applies platform-wide, so an origin allowlisted for Search also reaches the write doors.

The Data Commons service is a second service callers reach. `dcp_access.tf` grants `roles/run.invoker` on it to the apis runtime account, the datasets worker, and the origin catalogue, graph release and search catalogue jobs. In dfo-dev, `eval_reader.tf` grants it to `dfo-dev-apis-eval-reader`. Neither environment's DC service grants `allUsers`, so a caller without one of these grants gets 403.

The website and ai services mint tokens from the metadata server as their runtime accounts. In dfo-dev the apis repository's eval jobs mint them as `dfo-dev-apis-eval-reader` from the workflow's WIF credentials, and the sdk repository's end-to-end workflow mints them as `dfo-dev-sdk-e2e`. The Data Commons prototype calls the website's proxy and holds no grant on this service.

To add a caller, grant `roles/run.invoker` on this service in the caller's own stack, or add a principal no stack owns to `invoker_members`. The apis service logs each request as `dfo_platform.request` with `caller_token_present`, the unverified `email` and `aud` of the token, and the user agent, which shows who calls and which callers lack a token or a grant.

A developer reaches dfo-dev through a local proxy that attaches their own token, with a project role that carries `run.routes.invoke`, such as `roles/editor`, and points local base URLs at `http://localhost:8083`:

```bash
gcloud run services proxy dfo-dev-apis --region northamerica-northeast1 --project dev-fin-observatory --port 8083
```

If `allow_unauthenticated = false` cuts off a caller, restore public access by hand:

```bash
gcloud run services add-iam-policy-binding dfo-dev-apis --region northamerica-northeast1 --project dev-fin-observatory --member=allUsers --role=roles/run.invoker
```

In prod the same command names `dfo-prod-apis`, `--region europe-west1` and `--project prod-fin-observatory`:

```bash
gcloud run services add-iam-policy-binding dfo-prod-apis --region europe-west1 --project prod-fin-observatory --member=allUsers --role=roles/run.invoker
```

The stack's IAM grants are additive `google_cloud_run_v2_service_iam_member` resources, so the next apply neither removes the manual binding nor reports it. Reconcile by setting `allow_unauthenticated = true` in that environment's `env.auto.tfvars`, or by running `remove-iam-policy-binding` with the same arguments once the caller is fixed.

## APIs

`network.tf` declares one `google_project_service`, for `dns.googleapis.com`. The `consumer-psc-network` module's private zone and record set need it, and nothing else in this repo enables it. `run.googleapis.com`, `iam.googleapis.com`, and `secretmanager.googleapis.com` are already enabled project-wide by the `foundation` and `dcp` stacks. `compute.googleapis.com`, which `network.tf`'s VPC, subnet, address, and forwarding rule resources need, is already enabled project-wide by the `dcp` and `website` stacks.

## Datasets first-party principal

`datasets_first_party_principal.tf` generates the shared bearer value the Datasets publish door compares the `x-dfo-principal` header against (`datasets_api.doors.publish`), stores it as `dfo-dev-datasets-first-party-principal`, and mounts it on this service as `DATASETS_FIRST_PARTY_PRINCIPAL`. Unset, the door reads an empty allowlist and refuses every caller regardless of header, so this mount is what lets presentation-mcp's publish call succeed instead of drawing a `403 publish_not_permitted`. The pin door reads a separate value — see "Datasets pin principal" below.

This value is a second check behind Cloud Run IAM: only a caller holding an invoker grant can send it to publish. See "Caller authentication" above.

Humans who need to read the value directly are granted read on this one secret through `var.datasets_first_party_principal_readers`; empty by default, since the `apis` and `ai` services carry it between themselves through their own `secret_env_vars` grants and no human needs it yet. Rotation is bumping `datasets_first_party_principal_version` in `datasets_first_party_principal.tf`: the replacement version is created before the old one is destroyed, and this stack's own mount pins the version number rather than `latest`, so the same apply rolls a revision onto the new value here. The `ai` stack's mount reads `latest` instead (see that stack's README), so rotating here deletes the old version once the new one exists, but does not by itself reach that stack's running instances — they keep whatever value they read at startup until that stack's own next apply and rollout rolls a new revision.

## Datasets pin principal

`datasets_pin_principal.tf` generates a second shared bearer value the Datasets pin door compares the same `x-dfo-principal` header against (`datasets_api.doors.pin`), stores it as `dfo-dev-datasets-pin-principal`, and mounts it on this service as `DATASETS_PIN_FIRST_PARTY_PRINCIPAL`. It is a distinct value from the publish principal above, not a second reader of it: a pin has no unpin route, so a caller who reaches it commits a dataset artifact permanently, a narrower but more consequential grant than publish's, and the two doors' allowlists rotate independently.

Its only consumer is `dfo-dev-website-staging` (the `website` stack), which sends this value server-side on its own pin call when a visitor creates a share; see that stack's README for how `DFO_PRINCIPAL` reaches it and the exposure that follows from the website's own `allow_unauthenticated` setting.

This value is a second check behind Cloud Run IAM, as the publish principal above is: only a caller holding an invoker grant can send it to pin.

Humans who need to read the value directly are granted read on this one secret through `var.datasets_pin_principal_readers`; empty by default. Rotation is bumping `datasets_pin_principal_version` in `datasets_pin_principal.tf`: the replacement version is created before the old one is destroyed, and this stack's own mount pins the version number rather than `latest`, so the same apply rolls a revision onto the new value here. The `website` stack's mount reads `latest` instead, since it does not own the version resource; see that stack's README for what rolling a new website revision after a rotation requires.

## Live-refresh principal

`live_refresh_principal.tf` generates the shared bearer value that gates the routes a live Studio share calls each time it opens: `POST /api/datasets/frames/refresh` and the Presentation render routes (`POST /api/presentation/components/{component_id}/revisions/{revision}/render` and its `/render/data` export), which compare the `x-dfo-principal` header against it. It stores the value as `dfo-dev-live-refresh-principal` and mounts it on this service as `LIVE_REFRESH_PRINCIPAL`. Unset or empty, every one of those routes refuses. It is distinct from both datasets principals above, because the refresh routes rebuild frames and render cards without publishing or pinning, and the allowlists rotate independently.

Its consumers are `dfo-dev-ai` (the `ai` stack, where it gates `POST /api/studio/refresh`) and `dfo-dev-website-staging` (the `website` stack, which sends it server-side on the refresh and render calls); see those stacks' READMEs. Apply this stack first. The other two read the secret by id, and a revision that mounts a missing secret fails to start.

This value is a second check behind Cloud Run IAM, as the principals above are: only a caller holding an invoker grant can send it to the refresh routes.

Humans who need to read the value directly are granted read on this one secret through `var.live_refresh_principal_readers`; empty by default. Rotation is a bump of `live_refresh_principal_version` in `live_refresh_principal.tf`. The replacement version is created before the old one is destroyed, and this stack's own mount pins the version number, so the same apply rolls a revision onto the new value here. The `ai` and `website` stacks' mounts read `latest`, since they do not own the version resource. Their READMEs say what rolling a new revision after a rotation requires.

## Caller principal

`caller_principal.tf` generates the shared value that lets this service trust the `x-dfo-caller` header. The website and `dfo-dev-ai` send it as `x-dfo-caller-principal` beside that header, and `dfo_platform.caller.resolve_caller` names the caller by `x-dfo-caller` only when the two match, so the pin door and the per-caller allowances count each website visitor or `/mcp` client on its own. It stores the value as `dfo-dev-caller-principal` and mounts it on this service as `DFO_CALLER_PRINCIPAL`. Unset or empty, the service trusts no `x-dfo-caller` header. It is distinct from the three principals above, because it grants no route by itself, only trust in a caller name, and the allowlists rotate independently.

Its consumers are `dfo-dev-ai` and `dfo-dev-website-staging`, which mount it as `DFO_CALLER_PRINCIPAL`; see those stacks' READMEs. Apply this stack first, for the reason the live-refresh principal gives. A caller holding an invoker grant who learns the value can name itself as any visitor and spend that visitor's allowances.

Readers, rotation and the `latest` mounts in `ai` and `website` work as for the live-refresh principal, through `var.caller_principal_readers` and a bump of `caller_principal_version` in `caller_principal.tf`.

## Caller HMAC key

`caller_hmac_key.tf` generates the key that names a client by a keyed digest of its address, stores it as `dfo-dev-caller-hmac-key`, and mounts it on this service as `DFO_CALLER_HMAC_KEY`, pinned to its version. The website mounts the same secret as `CALLER_HMAC_KEY` and sends the digest as `x-dfo-caller`, so this service and the website name a client by one digest. The digest is the `ip:` caller in the combined MCP server's request log lines, the frame `writer` data-mcp and analysis-mcp record, and the key of each per-caller allowance here. This stack owns the key because it applies before `website`.

The key moved here from the `website` stack, whose `dfo-dev-website-staging-caller-hmac-key` that move destroyed. The new key is a fresh value, so every visitor's `ip:` caller id changed once on that apply, and allowance rows keyed by the old digest stopped matching anyone.

Rotation changes every visitor's caller id the same way. Bump `caller_hmac_key_version` in `caller_hmac_key.tf`. This stack's pinned mount rolls `dfo-dev-apis` onto the new key in the same apply. The website's mount reads `latest`, so it keeps the old key until a new revision: run a `dfo-website` deploy of the `staging` branch, or `gcloud run services update dfo-dev-website-staging --region northamerica-northeast1 --update-labels=caller-hmac-key-rotated=<n>`. Until then the two services name the same visitor by different digests. Humans who need the value read it through `var.caller_hmac_key_readers`, empty by default.

## Share import principal

`share_import_principal.tf` generates the shared bearer value that gates `PUT /api/presentation/shares/{share_id}/import`, which compares the `x-dfo-principal` header against it. It stores the value as `dfo-dev-share-import-principal` and mounts it on this service as `PRESENTATION_SHARE_IMPORT_PRINCIPAL`, pinned to its version. Unset or empty, the route refuses every caller. It is distinct from every other principal here, because the route creates shares under ids and creation times the caller chooses and spends no allowance.

Its only consumer is the `website` stack's share migration Job, `dfo-dev-website-staging-share-migrate`, which reads it as `PRESENTATION_SHARE_IMPORT_PRINCIPAL` through `var.share_import_principal_secret_id`; see that stack's README. Apply this stack first, since the website stack grants the Job read on the secret. A caller holding an invoker grant who learns the value can create shares. No human reader grant exists. Rotation is a bump of `share_import_principal_version` in `share_import_principal.tf`.

The route, this secret and the website Job are removed once prod's shares are migrated.

## Origin catalogue

`origin_catalogue.tf` declares the catalogue's own bucket (`dfo-dev-origin-catalogue-<project>`), a Cloud Run Job (`dfo-dev-origin-catalogue`) running `python -m origin_catalogue.job` from the dfo-apis image, a Cloud Scheduler trigger (`dfo-dev-origin-catalogue-tick`) every 15 minutes, and an alert policy for a stale publish, a failed execution, or a job that stopped running. The job builds the table of every provenance (DFO, base Data Commons and the UN System Data Commons) with its variables and topics, publishes each build under `format-<n>/versions/<build id>/`, and moves `format-<n>/current.json` to point at it last. The operator page is `deploy/origin-catalogue.md` in dfo-apis.

The job runs as `dfo-dev-origin-catalogue-job`, which holds `roles/bigquery.jobUser`, `roles/bigquery.connectionUser` on the Spanner connection, `roles/spanner.databaseReader` on the database and `roles/spanner.viewer` on the instance, the grants `EXTERNAL_QUERY` against Spanner needs as the caller. It holds no `roles/bigquery.readSessionUser`, because the job pages query results through `jobs.getQueryResults`, opens no BigQuery Storage read session, and its image does not install `google-cloud-bigquery-storage`. It has `roles/storage.objectUser` on its own bucket. The Scheduler runs as `dfo-dev-origin-cat-scheduler`, which holds `roles/run.invoker` on this one Job.

The task timeout is 7200 seconds and must equal `_MAX_RUN_SECONDS` in `origin_catalogue.job`, because a lease lapses after that long. A run that rebuilds the base tables (a registry edit, a new ISO week, or an image that changes `origin_catalogue`'s enumeration code) takes about 11 minutes on the dev graph, and an ingestion carries them forward and publishes in minutes. A run whose identity is already published, or which another run leased, exits in seconds. The Job has no retries. The Scheduler polls every 15 minutes and the lease keeps overlapping executions from both building. The Job has 1 CPU and 2 GiB. A full build against the dev graph peaks at about 560 MiB resident over 11 minutes, and the run waits on mixer round trips more than on compute.

The Job reads the mixer at `DATASETS_GRAPH_BASE_URL` and the UN System Data Commons at `UN_GRAPH_BASE_URL` over the default route. `DATASETS_GRAPH_TOKEN` is unset for the reason given under Datasets API environment. `var.un_graph_base_url` sets `UN_GRAPH_BASE_URL` on the Job, the apis service and the datasets worker alike, the one name dfo-apis reads for the UN deployment, because a build records UN rows and the places the UN front door refuses from the deployment it read.

Two alert policies watch the job. The first has two conditions. The job logs `origin_catalogue_publish_stale` when an identity has gone unpublished for more than one cycle, including while `IngestionLock` holds it off, and when the published build is older than a week plus one run and one cycle. The stale condition sums that log metric over 15 minutes. The failed-execution condition reads Cloud Run's `completed_execution_count` for `result="failed"`, which a refusal, a failed read or an OOM kill produces. Every run that exits 0 logs `origin_catalogue_job_heartbeat` last, with the published build and its age. The second policy, which auto-closes after a week, fires when no heartbeat arrives for 9000 seconds. Each 15-minute execution is its own run, and one that finds the build lease held returns and heartbeats. The window exceeds the 7200-second timeout plus one cycle, so one hung or timed-out build cannot open the alert on its own. A Scheduler that stops starting the job logs nothing and fails nothing, so only the heartbeat's absence shows it. Pausing the Scheduler opens that incident once heartbeats have started. The first policy auto-closes after an hour.

`ORIGIN_CATALOGUE_URI` is set on the apis service (`main.tf`) and the datasets worker (`datasets_worker.tf`), and both runtime accounts hold `roles/storage.objectViewer` on the bucket. Both raise at startup when no published catalogue loads.

## Graph release

`graph_release.tf` declares the builder's own bucket (`dfo-dev-graph-release-<project>`), a Cloud Run Job (`dfo-dev-graph-release`) running `python -m graph_release.job` from the dfo-apis image, a Cloud Scheduler trigger (`dfo-dev-graph-release-tick`) every 2 minutes, and five alert policies. The job reads the Data Commons Spanner database, gates the result, and publishes an immutable release of the platform tables and DFO parts to the bucket, moving one pointer last. The job account holds `roles/spanner.databaseReader` on the database, `roles/run.viewer` on the Data Commons service, `roles/storage.objectUser` on the bucket. The apis runtime and datasets worker accounts hold `roles/storage.objectViewer` on the bucket.

`graph_release_enabled` defaults to false, which creates the Scheduler trigger paused and the alert policies disabled. Apply the stack with it off, deploy the dfo-apis image that carries `graph_release.job`, then set it true. The task timeout is 1800 seconds, equal to the job's lease ttl, and the Job has 2 CPU, 8 GiB and no retries.

The apis service and the datasets worker load the release in process and log two events that neither stops the service. `graph_release_refused` is logged at `ERROR`, once per release id, when an instance declines a release it cannot serve and keeps the one it holds. `graph_release_recheck_failed` is logged at `WARNING` on every failed or skipped recheck of the pointer, about once a minute per instance while it fails. Two log metrics count them across both services, and one policy, `graph_release_serving`, watches both. The refused condition fires on any occurrence. The recheck condition fires when the metric stays above zero for 10 minutes. A separate policy, `graph_release_memory`, fires when the p99 of Cloud Run's `container/memory/utilizations` over 5 minutes exceeds 80% on either service, since a swap holds the serving release and the incoming one in memory together. A fifth policy, `graph_release_blind_spots`, is a notice. The builder's `graph_release_published` line carries `blind_spots.shared` and `blind_spots.unread`, counts of variables outside the release in its own families. A release with either above zero still publishes and serves, so a log metric counts those publishes and the policy fires on any occurrence. Its documentation text says that serving may miss members if the origin catalogue does not list them, and points to `deploy/graph-release.md` step 6 in dfo-apis.

The serving, memory and blind-spot policies are disabled while `graph_release_enabled` is false, and their incidents auto-close after an hour.

The apis service has 4 GiB of memory for the coverage index and its temporary reload copies.

## Search catalogue

`search_catalogue.tf` declares the catalogue's own bucket (`dfo-dev-search-catalogue-<project>`), a Cloud Run Job (`dfo-dev-search-catalogue`) running `python -m search.catalogue.job` from the dfo-apis image, and alert policies for a failed execution and a dropped example. The job runs each example sentence in dfo-apis's `search/catalogue/examples.toml` through the search engine in-process, keeps the ones that answer with data, counts publishers, countries and aid, publishes each build under `format-<n>/versions/<build id>/`, and moves `format-<n>/current.json` to point at it last. The apis service serves the published build at `GET /api/search/catalogue`.

The build key is the origin catalogue build, the graph release id (while `graph_release_coverage` is true), `DFO_BUILD_COMMIT` and a digest of the examples file. A run whose key is already published exits in seconds without loading either artifact, so the job rebuilds only after one of the two artifacts publishes or a deploy moves the image.

The graph release builder starts the job after each publish, and the dfo-apis deploy workflow runs it after each deploy. `search_catalogue_tick`, true by default, adds a Cloud Scheduler trigger (`dfo-dev-search-catalogue-tick`) every 15 minutes, its trigger account and the heartbeat alert. Dev and prod set it false: a start that meets a running build waits for its lease, so no trigger is lost, and without the tick a quiet hour would open the heartbeat alert. Terraform refuses false unless `graph_release_enabled` is true. A build makes about 30 Gemini and graph calls, takes about 90 seconds and peaks near 1.2 GB resident.

The job runs as `dfo-dev-search-catalogue-job`, which holds `roles/storage.objectUser` on its own bucket, `roles/storage.objectViewer` on the origin catalogue bucket, and `roles/secretmanager.secretAccessor` on the secret `var.search_catalogue_gemini_api_key_secret_id` names, `dfo-dev-gemini-api-key` in dev and the job's own `dfo-prod-search-catalogue-gemini-api-key` in prod. It reads the graph at `SEARCH_GRAPH_BASE` with an ID token and the UN System Data Commons at `UN_GRAPH_BASE_URL` anonymously, both over the default route, with the engine settings the apis service gets from `main.tf`. The resolvekit cache and `DFO_BUILD_COMMIT` come from the image. While the tick exists, its Scheduler runs as `dfo-dev-search-cat-scheduler`, which holds `roles/run.invoker` on this one Job. The apis runtime account holds `roles/storage.objectViewer` on the bucket, and `main.tf` sets `SEARCH_CATALOGUE_URI` on the service.

The task timeout is 1800 seconds and equals `_MAX_RUN_SECONDS` in `search.catalogue.job`, which the job also uses as the grace before pruning old builds. The lease lapses `LEASE_TTL_SECONDS` (600) after it is taken, and a run that meets a held lease waits up to one lease for it, so the timeout leaves a waiting run time to load, build and publish. The Job has no retries: a failed build waits for the next publish, deploy or tick. It has 1 CPU and 4 GiB, the apis service's limits, because it loads the same coverage index and origin catalogue.

Three alert policies watch the job. The job logs `search_catalogue_job_failed` or `search_catalogue_job_refused` at `ERROR` and exits 1, so the first policy reads Cloud Run's `completed_execution_count` for `result="failed"`, which also catches an import error, an OOM kill or a timeout that never logs. A refused build publishes nothing and the last published build keeps serving. The second policy sums `search_catalogue_line_dropped` over 15 minutes. The job logs it at `WARNING` for each example that fails its presence check or an engine run, and still publishes and exits 0 when at least five examples pass. Every run that exits 0 logs `search_catalogue_job_heartbeat` last. While `search_catalogue_tick` is true, a log metric counts it and a third policy, which auto-closes after a week, fires when no heartbeat arrives for 3600 seconds, longer than the timeout plus one cycle. The first two auto-close after an hour.

## Alert notifications

Every alert policy in this stack notifies the channel whose display name `alert_notification_channel` holds, looked up in `main.tf` with a `google_monitoring_notification_channel` data source. Plan fails unless exactly one channel in the project has that name. Prod sets it to `Telemetry pipeline alerts: team`, the email channel the telemetry stack builds from the `alerts` object in `dfo-prod-telemetry-principals`, so the addresses stay in that secret. Dev leaves it null, since dev has no channel, and its policies record incidents in Cloud Monitoring without notifying anyone.

## Search failure alert

`search_alert.tf` declares two log metrics on `dfo-dev-apis` and one alert policy, `Search failing on the apis service`, that fires on either. The first metric counts the `Engine infrastructure error:` lines the `search.engine.app` logger writes at `ERROR` for every engine infrastructure failure, such as Gemini rejecting the key or the graph answering 500. The second counts 5xx answers on `/api/search/resolve` in Cloud Run's request log, which also covers crashes and front-end timeouts the engine never logs. A revision with a key Gemini rejects starts, takes traffic and answers 503 to every search, so these metrics are the only alert for it. Each condition sums its metric across revisions over a rolling 5 minutes and opens at three or more. Over the 14 days to 2026-10-24 prod logged one or two failures in a 5-minute window 17 times outside outages, and three or more only during outages, so the policy stays quiet for a lone failure and opens within 5 minutes of the first three failed searches. The documentation on the policy tells the responder to read the service's errors and compare the Gemini key version the failing revision started on with the previous one. The policy auto-closes after an hour.

## Client-call metric

`client_calls.tf` declares a log-based metric, `dfo-dev-client-calls`, over the service's `dfo_platform.request` lines. It counts HTTP requests that name a client in the `X-DFO-Client` header, labelled by `client` and `status`, whether they come through the website or straight to this service. The `client` label is `dfo-python`, `dfo-ts`, or empty for any other name.

The count is of requests, so one library call that polls, re-posts, retries or downloads files counts many times. A browser's dataset download carries no `X-DFO-Client` and is missed, and so is anything refused before the app logs it: the website's and Cloudflare's rate limits, a crash, a front-end timeout. Use the `run.googleapis.com/requests` log for failure rates. Dev's series includes the sdk repository's daily end-to-end workflow.

## The async worker

`datasets_worker.tf` declares a second Cloud Run service, `dfo-dev-datasets-worker`, for Datasets mints whose estimate exceeds the synchronous budget. A mint over that budget returns 202 with an operation id instead of running inline; the mint door enqueues a Cloud Tasks task naming that id, the worker claims the corresponding leased row in `datasets.operation`, runs the same materialisation path the synchronous door runs, and the caller polls the operation id for the result.

It runs as its own service account, `dfo-dev-datasets-worker-run`, with its own Postgres IAM user (`google_sql_user.datasets_worker_runtime`). The account holds object create and view on the working and pinned buckets, view on the origin catalogue bucket and Cloud SQL client and login. The worker-role migration in dfo-apis grants the apis runtime role to the worker's database user, so the worker reads and writes `datasets.operation` and the version tables with the same privileges as the mint door. The datasets migrate job receives the worker's database user name as `DATASET_STORE_WORKER_DB_USER` for that grant.

The service sets `ingress = "INGRESS_TRAFFIC_INTERNAL_ONLY"` and grants `roles/run.invoker` to one dedicated bearer identity, `dfo-dev-worker-invoker`, rather than `allUsers`: Cloud Tasks mints an OIDC token as that account when it dispatches a task, and Cloud Run IAM verifies the token before the request reaches the container. The app itself checks the token's audience and email as a second layer (out of scope here). `dfo-dev-datasets-worker` is declared as a raw `google_cloud_run_v2_service` rather than through `../../modules/cloud-run-service`: that module always mints its own dedicated runtime account, the same divergence the two migrate Jobs already have from the module for a different reason (Jobs aren't modelled by it at all).

The queue, `dfo-dev-datasets-worker` (Cloud Tasks), bounds concurrent dispatches to 4, matching the service's `max_instance_count`. `dispatch_deadline` is not a queue-level setting on `google_cloud_tasks_queue` — the app sets it per task at 1800 seconds, Cloud Tasks' own ceiling for an HTTP target, and the worker's container timeout (1860 seconds) sits just above it so Cloud Run never cancels a request Cloud Tasks is still willing to wait on. The apis runtime identity gets `roles/cloudtasks.enqueuer` on this one queue and `roles/iam.serviceAccountUser` on the invoker identity's own resource, never project-wide, so enqueuing a task can name the invoker account as the task's OIDC principal without reaching any other service account in the project. Each claimed operation holds a static lease of `run_deadline_seconds = 1620` from `claimed_at`: a 1,500 s work deadline plus 120 s of grace. A delivery inside the lease answers 409, and only a delivery after `claimed_at + 1620 s` can re-claim. The retry bounds (`max_attempts = 3`, `min_backoff = "1680s"`, `max_backoff = "1680s"`, `max_doublings = 0`, `max_retry_duration = "3360s"`) keep the first retry out of that lease. A worker that dies the instant it claims fails its delivery at or after `claimed_at`, and the retry lands 1,680 s later, 60 s past the lease. A shorter `min_backoff` meets the live lease, gets a 409 and burns an attempt. `datasets_worker.tf` derives the backoff from the 1,620 s lease plus 60 s of slack for clock skew, so the two cannot drift apart in this stack. Cloud Tasks stops retrying only when `max_attempts` is reached and `max_retry_duration` has passed, so a longer duration adds attempts beyond `max_attempts`. `max_retry_duration` is therefore `(max_attempts - 1) * min_backoff`, the fastest start of the last attempt, which makes `max_attempts` the exact bound. If every attempt runs the full 1,800 s dispatch deadline, the three attempts take 3 * 1,800 + 2 * 1,680 = 8,760 s. A full backlog of 20 operations (`DATASETS_OPERATION_BACKLOG_MAX`) drains 4 dispatches at a time, so a delivery waits up to ceil(20 / 4) * 1,800 = 9,000 s for a slot, and retries of other tasks compete for the same slots. `DATASETS_OPERATION_DEADLINE_SECONDS` is dfo-apis's own deadline for one submission of an operation, which the apis service and the worker both read: an operation still unfinished that long after its dispatch fails retryable at the next poll, whatever the queue still holds. It lets each of the three deliveries wait out a full backlog and run its dispatch deadline, with the two backoffs and a 240 s margin: 3 * (9,000 + 1,800) + 2 * 1,680 + 240 = 36,000 s. `DATASETS_OPERATION_MAX_ATTEMPTS` carries `max_attempts`. All are derived from the same locals.

`main.tf`'s env carries `DFO_WORKER_URL`, `DFO_WORKER_INVOKER_SERVICE_ACCOUNT` and `DFO_TASKS_QUEUE`, read from this file's outputs, for the mint door to dispatch an over-budget operation. The worker service mounts the same first two values on itself, because its shared config module reads them unconditionally regardless of surface. `google_cloud_run_v2_service.datasets_worker.uri` can't supply either value there — a resource cannot reference its own computed attribute — so both mounts read `local.datasets_worker_url`, this stack's own deterministic Cloud Run URL (`https://<service-name>-<project-number>.<region>.run.app`, per ["Invoke with an HTTPS request"](https://cloud.google.com/run/docs/triggering/https-request)), built from a `data "google_project"` lookup instead. `main.tf` and `datasets_worker.tf` read that same local, so the URL the worker sees on itself and the one the apis service dispatches to can never disagree.

The deploy pipeline updates this service's image with the same image-only `gcloud run services update` call it already makes against the apis service, so the deployer identity carries the matching grants: `roles/run.developer` on the worker service and `roles/iam.serviceAccountUser` on the worker's runtime service account, both declared in `datasets_worker.tf` alongside the apis service's own equivalents.

## Datasets maintenance

`datasets_maintenance_job.tf` declares the Cloud Run Job `dfo-dev-datasets-maintenance`. It runs the apis image with the entrypoint `datasets-maintenance` and no default args, so an execution names its task in the args. The Job runs as the apis runtime service account, which holds object create and view on the working and pinned buckets and the runtime Postgres role. Its environment carries `DATASETS_ARTIFACT_BUCKET_WORKING`, `DATASETS_ARTIFACT_BUCKET_PINNED`, `DATASET_STORE_INSTANCE_CONNECTION_NAME`, `DATASET_STORE_RUNTIME_DB_USER`, `PRESENTATION_STORE_INSTANCE_CONNECTION_NAME`, `PRESENTATION_STORE_RUNTIME_DB_USER` and `DATASETS_OPERATION_DEADLINE_SECONDS` (the deadline `age-operations` judges an abandoned operation by), the same values the apis service reads. The Presentation pair lets `normalise-recipes` and `take-down-share` reach the Presentation store as the same runtime Postgres role the service uses, so they need no further grant. When `graph_release_serving` is true it also carries `GRAPH_RELEASE_URI`, the apis service's value, because `backfill-descriptions`, which every deploy runs, opens the graph release. The apis runtime service account reads that bucket through `graph_release_apis_runtime_viewer`.

Two tasks run daily from Cloud Scheduler as `dfo-dev-datasets-sweep` (03:00 UTC) and `dfo-dev-datasets-age-operations` (03:30 UTC). `sweep` reads both artifact tiers and logs orphaned, missing and unreferenced counts. `age-operations` fails every abandoned row of `datasets.operation` as retryable (a `pending` or lease-ended `running` operation past `DATASETS_OPERATION_DEADLINE_SECONDS`, which the Job reads from the same local as the service and the worker, or a lease-ended one whose final delivery claimed it), then deletes `done` and `failed` rows older than 30 days. The runtime role can update and delete there: dataset_store migration `0001_bootstrap.sql` grants it SELECT, INSERT, UPDATE and DELETE on every later table in the `datasets` schema through `ALTER DEFAULT PRIVILEGES`. Each trigger posts to the Cloud Run Admin API with a container args override, as a dedicated service account (`dfo-dev-dsmaint-scheduler`) that holds `roles/run.jobsExecutorWithOverrides` on this one Job. `roles/run.invoker` is not enough, because an args override needs `run.jobs.runWithOverrides`.

`backfill-frame1` has no trigger. Run it once per environment, after the image that carries it is deployed to the Job:

```bash
gcloud run jobs execute dfo-dev-datasets-maintenance \
  --region=northamerica-northeast1 --project=dev-fin-observatory \
  --args=backfill-frame1 --wait
```

The deployer holds `roles/run.developer` on the Job, so the deploy pipeline can move its image with `gcloud run jobs update --image` (the name reaches dfo-apis as `JOB_DATASETS_MAINTENANCE`) and an operator can run the command above. Prod uses the same command with `dfo-prod-datasets-maintenance`, `--project=prod-fin-observatory` and `--region=europe-west1`.

## Search eval reader

`eval_reader.tf` gives the apis repo's search eval workflows a read-only identity, `dfo-dev-apis-eval-reader`. It holds `roles/storage.objectViewer` on the origin catalogue and graph release buckets and no project role. It also holds `roles/run.invoker` on `dfo-dev-apis` and on the Data Commons service, so the eval jobs call the service with an ID token minted as this account, and `roles/iam.serviceAccountOpenIdTokenCreator` on itself, which the IAM Credentials `generateIdToken` call needs when the job's credentials are this account's own. Any GitHub Actions run in `DevelopmentFinanceObservatory/apis` may impersonate it through the shared pool, matched on `attribute.repository_id`, since pull requests, pushes and the nightly schedule all run the eval. The pool's mapping carries no event attribute, and changing that mapping risks every GitHub run's access to GCP.

The pool id and the apis repository's id reach this stack as `github_wif_pool_id` and `dfo_apis_repository_id` defaults copied from the `foundation` stack. The apis repo needs two repository secrets for the eval workflows, because they run on pull requests and cannot read the `dev` environment's `WIF_PROVIDER` and `WIF_SA`. `EVAL_WIF_SA` takes the `eval_reader_service_account_email` output. `EVAL_WIF_PROVIDER` takes the `foundation` stack's `workload_identity_provider` output, `projects/41292283861/locations/global/workloadIdentityPools/github-pool/providers/github`.

## Deploy order

The apis service's readiness depends on the origin catalogue existing. The deploy workflow has to update and execute `dfo-dev-origin-catalogue` (`gcloud run jobs update --image` then `gcloud run jobs execute --wait`, the same two calls it already runs against the migrate Jobs) before it deploys the apis service. In the reverse order the first deploy races a service revision that raises at startup against a Job that has not yet produced an artifact.

## State bootstrap

This stack's state prefix has to exist before CI can plan it. `terraform init` creates the state on first run, creating it takes a lock on the bucket, and the read-only `dfo-infra-planner` service account CI plans as cannot write there. Until the prefix exists, `plan (apis)` fails on init with a 403 on `terraform/state/dfo-dev/apis/default.tflock`, and no flag on `init` avoids it: the write is the state creation, not the lock.

An owner with local credentials runs this once:

```bash
just auth
(cd infra/dfo-dev/apis && terraform init)
```

Every plan after that is an ordinary read. This applies to any new stack, not just this one.

## Handoff after `apply`

`dfo-apis`'s deploy workflow reads `REGION`, `PROJECT_ID`, `AR_REPO`, `SERVICE_APIS`, `SERVICE_WORKER`, `JOB_DATASETS_MIGRATE`, `JOB_DATASETS_MAINTENANCE`, `JOB_PRESENTATION_MIGRATE`, `JOB_ORIGIN_CATALOGUE`, `JOB_GRAPH_RELEASE` and `JOB_SEARCH_CATALOGUE` as variables and `WIF_PROVIDER` and `WIF_SA` as secrets from its `dev` GitHub Environment. Each is an output of this stack or `foundation`, and `deploy_values` in `scripts/deploy-targets.sh` maps each name to its output.

Run **`just handoff apis`** (`scripts/handoff.sh dfo-dev apis`) after applying the `foundation` and `apis` stacks, and again after either renames a resource it hands over. It reads those outputs and sets them on `dfo-apis`'s `dev` GitHub Environment with `gh`, using your GitHub login. Nothing else sets them.

The script uses `gh` because a Terraform `integrations/github` resource would need a long-lived GitHub admin credential stored in Secret Manager, which defeats the keyless WIF design. `dfo-apis`'s `deploy/README.md` describes how its workflow uses each value.
