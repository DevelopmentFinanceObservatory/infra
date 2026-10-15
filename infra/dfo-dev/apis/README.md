# apis — the DFO Search, Datasets and Graph APIs

One Cloud Run service, `dfo-dev-apis`, running the `dfo-apis` repo's image. It serves three APIs. The Search API resolves natural-language data requests against a Data Commons graph. The Datasets API serves dataset specs and artifacts, and this stack grants it the storage, database and private-network access it needs. The Graph API reads DCP (Data Commons Platform) directly and holds no persistence seam of its own, unlike Datasets.

The search engine also runs today as a passenger inside the Data Commons container in the `dcp` stack (see that stack's `dfo.tf`). This service is a second, independently-scaled place to reach it, not a replacement for that one.

The service is defined via the reusable `../../modules/cloud-run-service` module (see that module's README) — a dedicated runtime service account, scaling config, and env vars/secrets.

## Model credentials

The service reads `GEMINI_API_KEY` from the process environment — it warm-loads its Gemini client at startup, so a missing or invalid key fails the revision immediately rather than on the first request. This stack wires that env var to the existing `dfo-dev-gemini-api-key` Secret Manager secret — the same secret the `ai` stack and the `dcp` stack's in-container engine already use (`infra/dfo-dev/ai/main.tf`, `infra/dfo-dev/dcp/dfo.tf`). That secret is **not terraform-managed**; it's referenced here via a `data "google_secret_manager_secret"` source, not created. The runtime service account is granted `roles/secretmanager.secretAccessor` scoped to only that one secret.

## Graph and engine configuration

`SEARCH_GRAPH_BASE` and `SEARCH_ENGINE_MODEL` are declared as stack variables (see `variables.tf`) rather than inlined, so they're visible and overridable in one place.

`SEARCH_GRAPH_BASE` points at the `dfo-dev` Data Commons service, the same graph the Datasets variables below target. It serves unauthenticated reads behind no WAF, so `SEARCH_GRAPH_TOKEN` stays unset. It carries the `sdg` namespace but none of ONE's own imports, so the query families that depend on those resolve to `no_data`.

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

`DATASETS_GRAPH_TOKEN` is unset. The dev graph serves both the node API and SDMX anonymously, so there is no credential to carry. `DATASETS_SYNC_CEILING_ROWS` is unset too, leaving the app's own default of 50000, which it republishes on `GET /api/datasets/capabilities` with a flag marking it provisional.

`DATASET_STORE_INSTANCE_CONNECTION_NAME` and `DATASET_STORE_RUNTIME_DB_USER` give the app its runtime database path. The connection name routes the session through the Cloud SQL Python Connector rather than plain TCP, and the connector mints an IAM access token for the runtime service account, so `DATASET_STORE_RUNTIME_DB_PASSWORD` stays unset and there is no password to store or rotate. The username reads `google_sql_user.datasets_runtime` directly, the same resource that creates the Postgres role, so the name the app logs in as and the role that exists on the instance are one value. `DATASET_STORE_DATABASE` stays unset, leaving the app's own default of `datasets`, the database the `dcp` stack creates.

The connector reaches `sqladmin.googleapis.com` over the service's ordinary egress. `PRIVATE_RANGES_ONLY` sends only RFC 1918 destinations down the PSC subnet, and the Admin API answers on a public address, so that call takes the same route the Gemini client already takes.

`datasets_migrate_job.tf` deliberately omits the connection name and reaches the PSC endpoint address over plain TCP instead. The migrator is a `BUILT_IN` password user, so the connector buys it nothing.

The surface mounts. `DFO_DATASETS_SURFACE` reads `"true"` (see `variables.tf`), so the app imports its datasets package at startup and reads all of these variables to build its live registry. `GET /api/datasets/healthz` answering 200 proves only that the surface mounted: that route is static, declared in `datasets_api/doors/meta.py` with no live dependency, so it answers 200 whether or not the database path works. The check that actually exercises the runtime user's grants on the `datasets` schema is the first real `/api/datasets/*` request that reaches Postgres.

The connector path itself works. A Cloud Run Job running `python -m dataset_store.smoke` as the runtime service account, on this stack's PSC subnet with the same egress setting the service uses, opened an IAM-authenticated session to the `datasets` database and ran `SELECT 1` inside a transaction. That covers the identity, the network route, and the grants. The serving revision itself has run none of it, and `SELECT 1` reads no table, so the runtime user's privileges on the `datasets` schema remain untested.

## Public site origin

`DFO_PUBLIC_SITE_URL` is the origin of the public website, which also proxies `/api/*` to this service. dfo-apis builds every download bundle link on it, and a service that builds the datasets or presentation settings refuses to start without it. `main.tf` sets it on the apis service and `datasets_worker.tf` on the worker, both from `var.dfo_public_site_url`. `env.auto.tfvars` sets it to the staging website's Cloud Run URL, the `website` stack's `staging_service_url` output. The migration jobs and the coverage and catalogue jobs never build those settings and do not carry it. `DFO_SITE_DATASET_LINKS` is `true` on both, so bundles of a definition the website can replay print its `/data?spec=&v=` page. Apply this stack before rolling out a dfo-apis release that reads the variable.

## Graph API environment

The Graph surface reads DCP directly and holds no persistence seam of its own, so unlike Datasets it needs no bucket grants, no database access and no migration job.

`GRAPH_DCP_BASE_URL` (see "Graph and engine configuration" above for the URL shape) is the one variable its own lifespan requires once `DFO_GRAPH_SURFACE` is on, and there is no safe default for it. A revision carrying the flag on with this variable unset fails to serve any request at all, on any surface, not just `/api/graph/*`, because the lifespan runs before the first request lands. This stack always sets both together, so that failure mode does not arise here, but the two variables have to keep changing as a pair.

`GRAPH_DCP_TOKEN` is unset. It is the same WAF-skip secret Search's `SEARCH_GRAPH_TOKEN` and Datasets' `DATASETS_GRAPH_TOKEN` send to their own graph endpoints, and neither of those is set on this service: the dev graph serves reads anonymously behind no WAF, so there is no credential to carry.

The surface mounts. `DFO_GRAPH_SURFACE` reads `"true"` (see `variables.tf`), so the app mounts `GET /api/graph/healthz`, `POST /api/graph/resolve`, and `GET /api/graph/node/{dcid}` alongside Search and Datasets.

## Skills API environment

The Skills surface reads the same graph the Search surface reads, through Search's graph client and skills index, so it needs no bucket grants, database access, migration job, or variable beyond its flag. `DFO_SKILLS_SURFACE` reads `"true"` (see `variables.tf`), so the app mounts the Skills API at `/api/skills` alongside the other surfaces.

## Decisions on record

**`min_instances = 1`.** One warm instance avoids the user-visible wait while the engine loads its Gemini client. The idle instance incurs baseline billing.

**No startup probe.** The `cloud-run-service` module declares none because the bootstrap placeholder image (`gcr.io/cloudrun/hello`) serves no health path. A probe checking for it would fail the very first `apply`, before any real image exists. The real `dfo-apis` image serves `GET /api/search/healthz`; configuring a startup probe against that path requires the real image to be running, so it belongs in a later change when the image deployment workflow is in place.

**Caller authentication at Cloud Run IAM.** The service keeps the module's default `INGRESS_TRAFFIC_ALL`, since its callers reach it at the public `run.app` URL, and Cloud Run IAM decides which callers get through. See "Caller authentication" below.

## Caller authentication

Cloud Run IAM is the service's only identity boundary. Each `roles/run.invoker` grant on the service sits in the stack that owns the identity it names:

- `allow_unauthenticated`, set in this stack's `env.auto.tfvars`, grants it to `allUsers`. It is `false` in dfo-dev, which refuses anonymous callers, and `true` in dfo-prod, whose service accepts anonymous requests, including dataset creation and registration.
- `invoker_members`, set in the same file, grants it to each listed identity. It holds principals no stack owns. In dfo-dev it lists `group:dfo-dev-apis-invokers@one.org` for developers, and in dfo-prod it is empty.
- The `website` and `ai` stacks grant it to their own runtime service accounts, as `google_cloud_run_v2_service_iam_member.website_apis_invoker` in `infra/stacks/website/main.tf` and `google_cloud_run_v2_service_iam_member.ai_apis_invoker` in `infra/stacks/ai/main.tf`. Each names this service through its `apis_service_name` variable, copied from this stack's `service_name` output. `apply.yml` applies this stack first, so the service exists before either grant, and this stack names no account another stack creates.
- In dfo-dev, `eval_reader.tf` grants it to `dfo-dev-apis-eval-reader` by resource reference.

A caller authenticates with a Google ID token minted as one of those identities, with the service URL it calls as the audience (origin only, no path), sent as `X-Serverless-Authorization: Bearer <token>`. Cloud Run checks that header in preference to `Authorization` and strips the signature before the container sees it, so it never collides with the `Authorization` header the website proxy passes through or the ai bearer. In dfo-prod, where `allow_unauthenticated` is `true`, a request with a token in either header, valid or not, still gets a 200.

Publish, pin and the refresh routes also compare an `x-dfo-principal` value (the three principal sections below), so a direct caller needs that value as well. Public users keep anonymous dataset creation through the website's `/api/v1/datasets` proxy, which the edge rate-limits in prod. `DFO_CORS_ORIGINS` applies platform-wide, so an origin allowlisted for Search also reaches the write doors.

dfo-prod keeps `allow_unauthenticated = true` until every caller sends a token there. The website and ai services mint tokens from the metadata server as their runtime accounts, and the apis repository's eval jobs mint them as `dfo-dev-apis-eval-reader` from the workflow's WIF credentials. The Data Commons prototype calls the website's proxy, not this service, and holds no grant. The apis service logs each request as `dfo_platform.request` with `caller_token_present`, the unverified `email` and `aud` of the token, and the user agent. Before dfo-prod flips, 48 hours of its logs must show no request from the website, ai or CI user agents that carries no token or an `email` that holds no invoker grant.

A developer in the dfo-dev invokers group reaches the service through a local proxy that attaches their own token, and points local base URLs at `http://localhost:8083`:

```bash
gcloud run services proxy dfo-dev-apis --region northamerica-northeast1 --project dev-fin-observatory --port 8083
```

If a flip cuts off a caller, restore public access by hand:

```bash
gcloud run services add-iam-policy-binding dfo-dev-apis --region northamerica-northeast1 --project dev-fin-observatory --member=allUsers --role=roles/run.invoker
```

Prod uses `dfo-prod-apis`, `--region europe-west1` and `--project prod-fin-observatory`. The stack's IAM grants are additive `google_cloud_run_v2_service_iam_member` resources, so the next apply neither removes the manual binding nor reports it. Reconcile by setting `allow_unauthenticated = true` in that environment's `env.auto.tfvars`, or by running `remove-iam-policy-binding` with the same arguments once the caller is fixed.

## APIs

`network.tf` declares one `google_project_service`, for `dns.googleapis.com`. The `consumer-psc-network` module's private zone and record set need it, and nothing else in this repo enables it. `run.googleapis.com`, `iam.googleapis.com`, and `secretmanager.googleapis.com` are already enabled project-wide by the `foundation` and `dcp` stacks. `compute.googleapis.com`, which `network.tf`'s VPC, subnet, address, and forwarding rule resources need, is already enabled project-wide by the `dcp` and `website` stacks.

## Datasets first-party principal

`datasets_first_party_principal.tf` generates the shared bearer value the Datasets publish door compares the `x-dfo-principal` header against (`datasets_api.doors.publish`), stores it as `dfo-dev-datasets-first-party-principal`, and mounts it on this service as `DATASETS_FIRST_PARTY_PRINCIPAL`. Unset, the door reads an empty allowlist and refuses every caller regardless of header, so this mount is what lets presentation-mcp's publish call succeed instead of drawing a `403 publish_not_permitted`. The pin door reads a separate value — see "Datasets pin principal" below.

This value is a second check behind Cloud Run IAM. In dfo-prod, while `allow_unauthenticated` is true, an internet caller who learns it can send it on the same header and reach publish; in dfo-dev only a caller holding an invoker grant can. See "Caller authentication" above.

Humans who need to read the value directly are granted read on this one secret through `var.datasets_first_party_principal_readers`; empty by default, since the `apis` and `ai` services carry it between themselves through their own `secret_env_vars` grants and no human needs it yet. Rotation is bumping `datasets_first_party_principal_version` in `datasets_first_party_principal.tf`: the replacement version is created before the old one is destroyed, and this stack's own mount pins the version number rather than `latest`, so the same apply rolls a revision onto the new value here. The `ai` stack's mount reads `latest` instead (see that stack's README), so rotating here deletes the old version once the new one exists, but does not by itself reach that stack's running instances — they keep whatever value they read at startup until that stack's own next apply and rollout rolls a new revision.

## Datasets pin principal

`datasets_pin_principal.tf` generates a second shared bearer value the Datasets pin door compares the same `x-dfo-principal` header against (`datasets_api.doors.pin`), stores it as `dfo-dev-datasets-pin-principal`, and mounts it on this service as `DATASETS_PIN_FIRST_PARTY_PRINCIPAL`. It is a distinct value from the publish principal above, not a second reader of it: a pin has no unpin route, so a caller who reaches it commits a dataset artifact permanently, a narrower but more consequential grant than publish's, and the two doors' allowlists rotate independently.

Its only consumer is `dfo-dev-website-staging` (the `website` stack), which sends this value server-side on its own pin call when a visitor creates a share; see that stack's README for how `DFO_PRINCIPAL` reaches it and the exposure that follows from the website's own `allow_unauthenticated` setting.

This value carries the same caveat as the publish principal above: in dfo-prod, while `allow_unauthenticated` is true, an internet caller who learns it reaches pin.

Humans who need to read the value directly are granted read on this one secret through `var.datasets_pin_principal_readers`; empty by default. Rotation is bumping `datasets_pin_principal_version` in `datasets_pin_principal.tf`: the replacement version is created before the old one is destroyed, and this stack's own mount pins the version number rather than `latest`, so the same apply rolls a revision onto the new value here. The `website` stack's mount reads `latest` instead, since it does not own the version resource; see that stack's README for what rolling a new website revision after a rotation requires.

## Live-refresh principal

`live_refresh_principal.tf` generates the shared bearer value that gates the routes a live Studio share calls each time it opens: `POST /api/datasets/frames/refresh` and the Presentation render routes (`POST /api/presentation/components/{component_id}/revisions/{revision}/render` and its `/render/data` export), which compare the `x-dfo-principal` header against it. It stores the value as `dfo-dev-live-refresh-principal` and mounts it on this service as `LIVE_REFRESH_PRINCIPAL`. Unset or empty, every one of those routes refuses. It is distinct from both datasets principals above, because the refresh routes rebuild frames and render cards without publishing or pinning, and the allowlists rotate independently.

Its consumers are `dfo-dev-ai` (the `ai` stack, where it gates `POST /api/studio/refresh`) and `dfo-dev-website-staging` (the `website` stack, which sends it server-side on the refresh and render calls); see those stacks' READMEs. Apply this stack first. The other two read the secret by id, and a revision that mounts a missing secret fails to start.

This value carries the same caveat as the principals above: in dfo-prod, while `allow_unauthenticated` is true, an internet caller who learns it reaches the refresh routes.

Humans who need to read the value directly are granted read on this one secret through `var.live_refresh_principal_readers`; empty by default. Rotation is a bump of `live_refresh_principal_version` in `live_refresh_principal.tf`. The replacement version is created before the old one is destroyed, and this stack's own mount pins the version number, so the same apply rolls a revision onto the new value here. The `ai` and `website` stacks' mounts read `latest`, since they do not own the version resource. Their READMEs say what rolling a new revision after a rotation requires.

## Coverage index

`coverage.tf` declares the coverage artifact's own bucket (`dfo-dev-coverage-<project>`), a Cloud Run Job (`dfo-dev-coverage`) running `python -m series_coverage.job` from the dfo-apis image, a Cloud Scheduler trigger (`dfo-dev-coverage-tick`) every 15 minutes, and an alert policy for failed executions or a stale publish. The job has 8 GiB of memory and 2 CPU because its BigQuery reader currently buffers the complete result before building the Arrow table, about 1.2 KiB per row at peak. It builds a Parquet artifact from Spanner, one row per (variable, facet_id, donor, recipient), publishes each build under `versions/<stamp>/` and moves `current.json` to point at it last, and skips the build entirely when its fingerprint of the source data already matches the published stamp.

The schedule is a recovery poll, not a 15-minute rebuild. Each run still checks the ingestion lock and queries the source fingerprint. The upstream ingestion workflow comes from the pinned Data Commons module and exposes no post-success hook to this stack; do not remove the poll until an ingestion-completion trigger is wired after its lock release and serving restart. The dfo-apis deploy workflow also runs this job when the artifact format changes.

A dedicated bucket, not a prefix in an existing one: the Datasets working bucket (`dcp` stack) expires objects after 30 days, which would delete the artifact's `current.json` pointer during a quiet month and fail Search's and the mint door's startup; the Data Commons `dc_artifacts` ingestion bucket has its IAM owned by the vendored upstream module, and GCS grants no prefix-scoped IAM without per-object conditions, so a grant there would also hand the job write access to ingestion's own objects. The bucket carries no lifecycle rule: a bucket-level age rule cannot tell a quiet month with no new publish from genuine staleness, and would delete the version `current.json` still points at out from under it. The job prunes its own old `versions/` prefixes instead, keeping the current and previous stamp, after every successful publish and every no-op run.

The job's own service account (`dfo-dev-coverage-job`) holds `roles/bigquery.jobUser` at the project level (BigQuery job execution has no narrower scope), `roles/bigquery.connectionUser` on the `dfo_dev_dc_spanner_connection` BigQuery connection that dcp's vendored upstream module creates (referenced by id, not by a resource this stack owns), `roles/bigquery.readSessionUser` at the project level, and `roles/storage.objectUser` on the coverage bucket, since the job overwrites `current.json` on every publish. `objectUser` already includes delete alongside create, get and list, so the job's self-prune above needs no additional grant. The apis runtime service account gets `roles/storage.objectViewer` on the same bucket — read-only, since it only loads the artifact.

The alert policy watches the job's structured `jsonPayload.event = "coverage_publish_stale"` line and Cloud Run's failed-execution metric. The latter catches startup errors and OOM kills before the job can emit its own stale signal. There is no notification channel in this repo yet; set `coverage_notification_channels` to existing channel resource names to notify operators. Its default empty list records incidents in Cloud Monitoring without notifying anyone.

`DFO_APIS`'s own env carries `COVERAGE_ARTIFACT_URI` (`main.tf`), pointed at `gs://dfo-dev-coverage-<project>/`. Search and the mint door fail readiness when this artifact can't be loaded, the same fail-at-construction pattern the Datasets and Graph surfaces already use.

The apis service has 4 GiB of memory for the coverage index and its temporary reload copies. This is a rollout limit, not a substitute for changing dfo-apis's recheck path to read `current.json` before loading the full Parquet file.

## Origin catalogue

`origin_catalogue.tf` declares the catalogue's own bucket (`dfo-dev-origin-catalogue-<project>`), a Cloud Run Job (`dfo-dev-origin-catalogue`) running `python -m origin_catalogue.job` from the dfo-apis image, a Cloud Scheduler trigger (`dfo-dev-origin-catalogue-tick`) every 15 minutes, and an alert policy for a stale publish, a failed execution, or a job that stopped running. The job builds the table of every provenance (DFO, base Data Commons and the UN System Data Commons) with its variables and topics, publishes each build under `format-<n>/versions/<build id>/`, and moves `format-<n>/current.json` to point at it last. The operator page is `deploy/origin-catalogue.md` in dfo-apis.

The job runs as `dfo-dev-origin-catalogue-job`, which holds `roles/bigquery.jobUser`, `roles/bigquery.connectionUser` on the Spanner connection, `roles/spanner.databaseReader` on the database and `roles/spanner.viewer` on the instance, the grants `EXTERNAL_QUERY` against Spanner needs as the caller. It holds no `roles/bigquery.readSessionUser`, because the job pages query results through `jobs.getQueryResults`, opens no BigQuery Storage read session, and its image does not install `google-cloud-bigquery-storage`. It has `roles/storage.objectUser` on its own bucket. The Scheduler runs as `dfo-dev-origin-cat-scheduler`, which holds `roles/run.invoker` on this one Job.

The task timeout is 7200 seconds and must equal `_MAX_RUN_SECONDS` in `origin_catalogue.job`, because a lease lapses after that long. A run that rebuilds the base tables (a registry edit, a new ISO week, or an image that changes `origin_catalogue`'s enumeration code) takes about 11 minutes on the dev graph, and an ingestion carries them forward and publishes in minutes. A run whose identity is already published, or which another run leased, exits in seconds. The Job has no retries. The Scheduler polls every 15 minutes and the lease keeps overlapping executions from both building. The Job has 1 CPU and 2 GiB. A full build against the dev graph peaks at about 560 MiB resident over 11 minutes, and the run waits on mixer round trips more than on compute.

The Job reads the mixer at `DATASETS_GRAPH_BASE_URL` and the UN System Data Commons at `UN_GRAPH_BASE_URL` over the default route. `DATASETS_GRAPH_TOKEN` is unset for the reason given under Datasets API environment. `var.un_graph_base_url` sets `UN_GRAPH_BASE_URL` on the Job, the apis service and the datasets worker alike, the one name dfo-apis reads for the UN deployment, because a build records UN rows and the places the UN front door refuses from the deployment it read.

Two alert policies watch the job. The first has two conditions. The job logs `origin_catalogue_publish_stale` when an identity has gone unpublished for more than one cycle, including while `IngestionLock` holds it off, and when the published build is older than a week plus one run and one cycle. The stale condition sums that log metric over 15 minutes. The failed-execution condition reads Cloud Run's `completed_execution_count` for `result="failed"`, which a refusal, a failed read or an OOM kill produces. Every run that exits 0 logs `origin_catalogue_job_heartbeat` last, with the published build and its age. The second policy, which auto-closes after a week, fires when no heartbeat arrives for 9000 seconds. Each 15-minute execution is its own run, and one that finds the build lease held returns and heartbeats. The window exceeds the 7200-second timeout plus one cycle, so one hung or timed-out build cannot open the alert on its own. A Scheduler that stops starting the job logs nothing and fails nothing, so only the heartbeat's absence shows it. Pausing the Scheduler opens that incident once heartbeats have started. The first policy auto-closes after an hour. `origin_catalogue_notification_channels` names the channels to notify; its default empty list records incidents without notifying anyone.

`ORIGIN_CATALOGUE_URI` is set on the apis service (`main.tf`) and the datasets worker (`datasets_worker.tf`), and both runtime accounts hold `roles/storage.objectViewer` on the bucket. Both raise at startup when no published catalogue loads.

## Search catalogue

`search_catalogue.tf` declares the catalogue's own bucket (`dfo-dev-search-catalogue-<project>`), a Cloud Run Job (`dfo-dev-search-catalogue`) running `python -m search.catalogue.job` from the dfo-apis image, a Cloud Scheduler trigger (`dfo-dev-search-catalogue-tick`) every 15 minutes, and alert policies for a failed execution, a dropped example, and a job that stopped running. The job runs each example sentence in dfo-apis's `search/catalogue/examples.toml` through the search engine in-process, keeps the ones that answer with data, counts publishers, countries and aid, publishes each build under `format-<n>/versions/<build id>/`, and moves `format-<n>/current.json` to point at it last. The apis service serves the published build at `GET /api/search/catalogue`.

The build key is the origin catalogue build, the coverage index build, `DFO_BUILD_COMMIT` and a digest of the examples file. A run whose key is already published exits in seconds without loading either artifact, so the job rebuilds only after one of the two artifacts publishes or a deploy moves the image. A build makes about 30 Gemini and graph calls, takes about 90 seconds and peaks near 1.2 GB resident.

The job runs as `dfo-dev-search-catalogue-job`, which holds `roles/storage.objectUser` on its own bucket, `roles/storage.objectViewer` on the coverage and origin catalogue buckets, and `roles/secretmanager.secretAccessor` on `dfo-dev-gemini-api-key`. It reads the graph at `SEARCH_GRAPH_BASE` and the UN System Data Commons at `UN_GRAPH_BASE_URL` anonymously over the default route, with the engine settings the apis service gets from `main.tf`. The resolvekit cache and `DFO_BUILD_COMMIT` come from the image. The Scheduler runs as `dfo-dev-search-cat-scheduler`, which holds `roles/run.invoker` on this one Job. The apis runtime account holds `roles/storage.objectViewer` on the bucket, and `main.tf` sets `SEARCH_CATALOGUE_URI` on the service.

The task timeout is 1800 seconds and must equal `_MAX_RUN_SECONDS` in `search.catalogue.job`, because a lease lapses after that long. The Job has no retries, since the next 15-minute poll retries and the lease keeps overlapping executions from both building. It has 1 CPU and 4 GiB, the apis service's limits, because it loads the same coverage index and origin catalogue.

Three alert policies watch the job. The job logs `search_catalogue_job_failed` or `search_catalogue_job_refused` at `ERROR` and exits 1, so the first policy reads Cloud Run's `completed_execution_count` for `result="failed"`, which also catches an import error, an OOM kill or a timeout that never logs. A refused build publishes nothing and the last published build keeps serving. The second policy sums `search_catalogue_line_dropped` over 15 minutes. The job logs it at `WARNING` for each example that fails its presence check or an engine run, and still publishes and exits 0 when at least five examples pass. Every run that exits 0 logs `search_catalogue_job_heartbeat` last, and the third policy, which auto-closes after a week, fires when no heartbeat arrives for 3600 seconds, longer than the timeout plus one cycle. The first two auto-close after an hour. `search_catalogue_notification_channels` names the channels to notify; its default empty list records incidents without notifying anyone.

## The async worker

`datasets_worker.tf` declares a second Cloud Run service, `dfo-dev-datasets-worker`, for Datasets mints whose estimate exceeds the synchronous budget. A mint over that budget returns 202 with an operation id instead of running inline; the mint door enqueues a Cloud Tasks task naming that id, the worker claims the corresponding leased row in `datasets.operation`, runs the same materialisation path the synchronous door runs, and the caller polls the operation id for the result.

It runs as its own service account, `dfo-dev-datasets-worker-run`, with its own Postgres IAM user (`google_sql_user.datasets_worker_runtime`). The account holds object create and view on the working and pinned buckets, view on the coverage and origin catalogue buckets, and Cloud SQL client and login. The worker-role migration in dfo-apis grants the apis runtime role to the worker's database user, so the worker reads and writes `datasets.operation` and the version tables with the same privileges as the mint door. The datasets migrate job receives the worker's database user name as `DATASET_STORE_WORKER_DB_USER` for that grant.

The service sets `ingress = "INGRESS_TRAFFIC_INTERNAL_ONLY"` and grants `roles/run.invoker` to one dedicated bearer identity, `dfo-dev-worker-invoker`, rather than `allUsers`: Cloud Tasks mints an OIDC token as that account when it dispatches a task, and Cloud Run IAM verifies the token before the request reaches the container. The app itself checks the token's audience and email as a second layer (out of scope here). `dfo-dev-datasets-worker` is declared as a raw `google_cloud_run_v2_service` rather than through `../../modules/cloud-run-service`: that module always mints its own dedicated runtime account, the same divergence the two migrate Jobs already have from the module for a different reason (Jobs aren't modelled by it at all).

The queue, `dfo-dev-datasets-worker` (Cloud Tasks), bounds concurrent dispatches to 4, matching the service's `max_instance_count`. `dispatch_deadline` is not a queue-level setting on `google_cloud_tasks_queue` — the app sets it per task at 1800 seconds, Cloud Tasks' own ceiling for an HTTP target, and the worker's container timeout (1860 seconds) sits just above it so Cloud Run never cancels a request Cloud Tasks is still willing to wait on. The apis runtime identity gets `roles/cloudtasks.enqueuer` on this one queue and `roles/iam.serviceAccountUser` on the invoker identity's own resource, never project-wide, so enqueuing a task can name the invoker account as the task's OIDC principal without reaching any other service account in the project. Each claimed operation holds a static lease of `run_deadline_seconds = 1620` from `claimed_at`: a 1,500 s work deadline plus 120 s of grace. A delivery inside the lease answers 409, and only a delivery after `claimed_at + 1620 s` can re-claim. The retry bounds (`max_attempts = 3`, `min_backoff = "1680s"`, `max_backoff = "1680s"`, `max_doublings = 0`, `max_retry_duration = "3360s"`) keep the first retry out of that lease. A worker that dies the instant it claims fails its delivery at or after `claimed_at`, and the retry lands 1,680 s later, 60 s past the lease. A shorter `min_backoff` meets the live lease, gets a 409 and burns an attempt. `datasets_worker.tf` derives the backoff from the 1,620 s lease plus 60 s of slack for clock skew, so the two cannot drift apart in this stack. Cloud Tasks stops retrying only when `max_attempts` is reached and `max_retry_duration` has passed, so a longer duration adds attempts beyond `max_attempts`. `max_retry_duration` is therefore `(max_attempts - 1) * min_backoff`, the fastest start of the last attempt, which makes `max_attempts` the exact bound. If every attempt runs the full 1,800 s dispatch deadline, the three attempts take 3 * 1,800 + 2 * 1,680 = 8,760 s. A full backlog of 20 operations (`DATASETS_OPERATION_BACKLOG_MAX`) drains 4 dispatches at a time, so a delivery waits up to ceil(20 / 4) * 1,800 = 9,000 s for a slot, and retries of other tasks compete for the same slots. `DATASETS_OPERATION_DEADLINE_SECONDS` is dfo-apis's own deadline for one submission of an operation, which the apis service and the worker both read: an operation still unfinished that long after its dispatch fails retryable at the next poll, whatever the queue still holds. It lets each of the three deliveries wait out a full backlog and run its dispatch deadline, with the two backoffs and a 240 s margin: 3 * (9,000 + 1,800) + 2 * 1,680 + 240 = 36,000 s. `DATASETS_OPERATION_MAX_ATTEMPTS` carries `max_attempts`. All are derived from the same locals.

`main.tf`'s env carries `DFO_WORKER_URL`, `DFO_WORKER_INVOKER_SERVICE_ACCOUNT` and `DFO_TASKS_QUEUE`, read from this file's outputs, for the mint door to dispatch an over-budget operation. The worker service mounts the same first two values on itself, because its shared config module reads them unconditionally regardless of surface. `google_cloud_run_v2_service.datasets_worker.uri` can't supply either value there — a resource cannot reference its own computed attribute — so both mounts read `local.datasets_worker_url`, this stack's own deterministic Cloud Run URL (`https://<service-name>-<project-number>.<region>.run.app`, per ["Invoke with an HTTPS request"](https://cloud.google.com/run/docs/triggering/https-request)), built from a `data "google_project"` lookup instead. `main.tf` and `datasets_worker.tf` read that same local, so the URL the worker sees on itself and the one the apis service dispatches to can never disagree.

The deploy pipeline updates this service's image with the same image-only `gcloud run services update` call it already makes against the apis service, so the deployer identity carries the matching grants: `roles/run.developer` on the worker service and `roles/iam.serviceAccountUser` on the worker's runtime service account, both declared in `datasets_worker.tf` alongside the apis service's own equivalents.

## Datasets maintenance

`datasets_maintenance_job.tf` declares the Cloud Run Job `dfo-dev-datasets-maintenance`. It runs the apis image with the entrypoint `datasets-maintenance` and no default args, so an execution names its task in the args. The Job runs as the apis runtime service account, which holds object create and view on the working and pinned buckets and the runtime Postgres role. Its environment carries `DATASETS_ARTIFACT_BUCKET_WORKING`, `DATASETS_ARTIFACT_BUCKET_PINNED`, `DATASET_STORE_INSTANCE_CONNECTION_NAME`, `DATASET_STORE_RUNTIME_DB_USER` and `DATASETS_OPERATION_DEADLINE_SECONDS` (the deadline `age-operations` judges an abandoned operation by), the same values the apis service reads.

Two tasks run daily from Cloud Scheduler as `dfo-dev-datasets-sweep` (03:00 UTC) and `dfo-dev-datasets-age-operations` (03:30 UTC). `sweep` reads both artifact tiers and logs orphaned, missing and unreferenced counts. `age-operations` fails every abandoned row of `datasets.operation` as retryable (a `pending` or lease-ended `running` operation past `DATASETS_OPERATION_DEADLINE_SECONDS`, which the Job reads from the same local as the service and the worker, or a lease-ended one whose final delivery claimed it), then deletes `done` and `failed` rows older than 30 days. The runtime role can update and delete there: dataset_store migration `0001_bootstrap.sql` grants it SELECT, INSERT, UPDATE and DELETE on every later table in the `datasets` schema through `ALTER DEFAULT PRIVILEGES`. Each trigger posts to the Cloud Run Admin API with a container args override, as a dedicated service account (`dfo-dev-dsmaint-scheduler`) that holds `roles/run.jobsExecutorWithOverrides` on this one Job. `roles/run.invoker` is not enough, because an args override needs `run.jobs.runWithOverrides`.

`backfill-frame1` has no trigger. Run it once per environment, after the image that carries it is deployed to the Job:

```bash
gcloud run jobs execute dfo-dev-datasets-maintenance \
  --region=northamerica-northeast1 --project=dev-fin-observatory \
  --args=backfill-frame1 --wait
```

The deployer holds `roles/run.developer` on the Job, so the deploy pipeline can move its image with `gcloud run jobs update --image` (the name reaches dfo-apis as `JOB_DATASETS_MAINTENANCE`) and an operator can run the command above. Prod uses the same command with `dfo-prod-datasets-maintenance`, `--project=prod-fin-observatory` and `--region=europe-west1`.

## Search eval reader

`eval_reader.tf` gives the apis repo's search eval workflows a read-only identity, `dfo-dev-apis-eval-reader`. It holds `roles/storage.objectViewer` on the coverage bucket and the origin catalogue bucket and no project role. It also holds `roles/run.invoker` on `dfo-dev-apis`, so the eval jobs call the service with an ID token minted as this account, and `roles/iam.serviceAccountOpenIdTokenCreator` on itself, which the IAM Credentials `generateIdToken` call needs when the job's credentials are this account's own. Any GitHub Actions run in `DevelopmentFinanceObservatory/apis` may impersonate it through the shared pool, matched on `attribute.repository_id`, since pull requests, pushes and the nightly schedule all run the eval. The pool's mapping carries no event attribute, and changing that mapping risks every GitHub run's access to GCP.

The pool id and the apis repository's id reach this stack as `github_wif_pool_id` and `dfo_apis_repository_id` defaults copied from the `foundation` stack. The apis repo needs two repository secrets for the eval workflows, because they run on pull requests and cannot read the `dev` environment's `WIF_PROVIDER` and `WIF_SA`. `EVAL_WIF_SA` takes the `eval_reader_service_account_email` output. `EVAL_WIF_PROVIDER` takes the `foundation` stack's `workload_identity_provider` output, `projects/41292283861/locations/global/workloadIdentityPools/github-pool/providers/github`.

## Deploy order

The apis service's readiness depends on the coverage artifact and the origin catalogue existing, and both Jobs' image is the same dfo-apis image that ships `series_coverage.job` and `origin_catalogue.job`. The deploy workflow has to update and execute the coverage Job (`gcloud run jobs update --image` then `gcloud run jobs execute --wait`, the same two calls it already runs against the migrate Jobs) before it deploys the apis service, and the same for `dfo-dev-origin-catalogue`. In the reverse order the first deploy races a service revision that raises at startup against a Job that has not yet produced an artifact.

## State bootstrap

This stack's state prefix has to exist before CI can plan it. `terraform init` creates the state on first run, creating it takes a lock on the bucket, and the read-only `dfo-infra-planner` service account CI plans as cannot write there. Until the prefix exists, `plan (apis)` fails on init with a 403 on `terraform/state/dfo-dev/apis/default.tflock`, and no flag on `init` avoids it: the write is the state creation, not the lock.

An owner with local credentials runs this once:

```bash
just auth
(cd infra/dfo-dev/apis && terraform init)
```

Every plan after that is an ordinary read. This applies to any new stack, not just this one.

## Handoff after `apply`

`dfo-apis`'s deploy workflow reads `REGION`, `PROJECT_ID`, `AR_REPO`, `SERVICE_APIS`, `SERVICE_WORKER`, `JOB_DATASETS_MIGRATE`, `JOB_DATASETS_MAINTENANCE`, `JOB_PRESENTATION_MIGRATE`, `JOB_COVERAGE`, `JOB_ORIGIN_CATALOGUE` and `JOB_SEARCH_CATALOGUE` as variables and `WIF_PROVIDER` and `WIF_SA` as secrets from its `dev` GitHub Environment. Each is an output of this stack or `foundation`, and `deploy_values` in `scripts/deploy-targets.sh` maps each name to its output.

Run **`just handoff apis`** (`scripts/handoff.sh dfo-dev apis`) after applying the `foundation` and `apis` stacks, and again after either renames a resource it hands over. It reads those outputs and sets them on `dfo-apis`'s `dev` GitHub Environment with `gh`, using your GitHub login. Nothing else sets them.

The script uses `gh` because a Terraform `integrations/github` resource would need a long-lived GitHub admin credential stored in Secret Manager, which defeats the keyless WIF design. `dfo-apis`'s `deploy/README.md` describes how its workflow uses each value.
