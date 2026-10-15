# ai — the DFO AI service

One Cloud Run service, `dfo-dev-ai`, running the `ai` repo's image: the agent harness with the search-mcp and analysis-mcp servers mounted in-process. The service consolidation rationale lives in that repo's `docs/architecture.md`.

The service is defined via the reusable `../../modules/cloud-run-service` module (see that module's README) — a dedicated runtime service account, scaling config, and env vars/secrets.

## Model credentials

The service reads `GOOGLE_API_KEY` from the process environment (google-adk's underlying `google-genai` client bypasses `ai`'s own settings classes for this). This stack wires that env var to the existing `dfo-dev-gemini-api-key` Secret Manager secret — the same secret the `dcp` stack's Search API already uses (`infra/dfo-dev/dcp/dfo.tf`). That secret is **not terraform-managed**; it's referenced here via a `data "google_secret_manager_secret"` source, not created. The runtime service account is granted `roles/secretmanager.secretAccessor` scoped to only that one secret.

## data-mcp environment

This stack sets one variable, `DFO_APIS_URL`, for the data-mcp component mounted inside the harness, which holds `/api/search` and `/api/datasets` as path-prefix constants to append to it. Unset, `DFO_APIS_URL` falls back to `http://localhost:8083` — an address nothing listens on inside this container. It is wired to the `dfo-dev-apis` Cloud Run service via `var.dfo_apis_url`, a bare host with no path suffix.

`var.dfo_apis_url` reaches this stack as a plain value in `env.auto.tfvars`, copied from the `apis` stack's `service_url` output rather than read via `terraform_remote_state` — the same rationale the `apis` stack records for its own cross-stack values — so a plan here never depends on that stack having applied.

`DATA_MCP_URL` and `ANALYSIS_MCP_URL`, which the harness also reads, stay unset. The harness derives both from `PORT` and reaches the two MCP servers over in-container loopback, which is the address this single-service topology wants.

## presentation-mcp environment

`PRESENTATION_PUBLIC_URL` is the browser-reachable prefix for presentation-mcp, set from `var.presentation_public_url`. Its value is the `dfo-dev-website-staging` origin plus `/mcp/presentation`. The website forwards `/mcp/presentation/theme-*.css` to this service's per-server mount, and the app views load their theme stylesheet through that URL. The service fails to start without it. It reaches this stack as a plain value in `env.auto.tfvars`, copied from the `website` stack's `website_url`, for the same no-dependency-on-apply reason as `var.dfo_apis_url`.

## analysis-mcp environment

The service receives `FRAME_STORE_BUCKET`, the name of the bucket for content-addressed analysis frames. The runtime service account can create and read objects. The bucket has no age rule, because a derived frame's object holds the only copy of its op-spec. [dfo-ai#187](https://github.com/ONEcampaign/dfo-ai/pull/187) owns the application change that writes analysis frames to the bucket.

## Studio engine

The stack sets `STUDIO_ENGINE` to `orchestrator`. The value `orchestrator` makes one agent answer a studio turn by calling tools itself, and `graph`, the harness default when the variable is unset, makes the workflow graph answer. Removing the entry returns the service to the graph engine on the next apply. The variable is declared here because an apply removes any variable set outside this stack.

## Ownership split with the `ai` repo

This stack owns the service _definition_; the `ai` repo's CI owns the _image_, updating it with image-only `gcloud run services update` calls. The module's `lifecycle.ignore_changes` on the container image is what makes that work without every `apply` reverting to the bootstrap placeholder image (`gcr.io/cloudrun/hello`) — see the module README for details.

## APIs

`run.googleapis.com`, `iam.googleapis.com`, and `secretmanager.googleapis.com` are already enabled project-wide by the `foundation` and `dcp` stacks, so this stack declares no `google_project_service` resource for them. `network.tf` declares one exception, `dns.googleapis.com`, for the PSC network's private zone.

## Private network path to Postgres

`network.tf` instantiates `../../modules/consumer-psc-network` on `10.100.4.0/24`, the next free `/24` for a `dfo-dev` consumer. The shared Cloud SQL instance in the `platform` stack binds to no VPC and instead publishes a Private Service Connect service attachment, so reachability is each consumer's own resource. `apis` and `website` already own one of these. `var.platform_psc_service_attachment_uri` and `var.platform_dns_name`, declared in `network.tf` itself, are plain values in `env.auto.tfvars` copied from that stack's outputs, the same copy-by-hand convention every cross-stack value in this repo follows, so this stack's plan never depends on `platform` having applied. `module.ai_service` takes `vpc_access` from the module's `network_id`/`subnetwork_id` outputs, giving the service direct VPC egress onto that subnet, hardcoded to `PRIVATE_RANGES_ONLY` with no NAT gateway.

## ADK session store

`session_store.tf` gives the harness's `DatabaseSessionService` a database on the shared Cloud SQL instance, `ai-sessions`, and one IAM database user for it, the runtime service account itself, the same identity `module.ai_service` runs as. ADK owns its schema end to end. `prepare_tables` runs SQLAlchemy `create_all` over the same connection the service reads and writes with. The one identity serves the harness and creates its own tables, unlike the `apis` stack's split between a runtime and a migration-runner identity for the datasets database. The runtime user holds `roles/cloudsql.client`, a login-only custom role (`cloudsql.instances.login`/`.get`, deliberately without `cloudsql.instances.executeSql`, the same reasoning `apis/datasets_access.tf` records), and CONNECT on the `ai-sessions` database with PUBLIC's default CONNECT revoked, plus USAGE and CREATE on that database's `public` schema so `create_all` can build its tables there.

Three env vars carry this to the service: `SESSION_STORE_INSTANCE_CONNECTION_NAME` (`var.platform_postgres_connection_name`, a plain value copied from the `platform` stack's `connection_name` output), `SESSION_STORE_DATABASE` (`google_sql_database.ai_sessions.name`), and `SESSION_STORE_RUNTIME_DB_USER` (`google_sql_user.ai_sessions_runtime.name`). The connector authenticates this identity over IAM, so there is no password var to mount. This database holds only what ADK's own `create_all` creates, which is what keeps a self-migrating schema safe to host.

`module.ai_service`'s `readiness_dependencies` lists the ids of the two `roles/cloudsql.client`/login-role grants and the two `google_sql_provision_script` resources above, so the revision is created only after those four apply. That orders Terraform's own apply. IAM grant propagation and the runtime user's first successful login still happen on Google's own schedule after the apply, independent of Terraform, which is what the harness's own startup retry on `prepare_tables` covers.

## Instance cap

`module.ai_service` sets `service_max_instances = 2`, a combined ceiling across every revision receiving traffic (see the module README's "Service-level instance cap" section for the mechanism). An old revision still draining SSE streams keeps its pool through a rollout, so up to four instances can hold connections at once. Four instances holding the harness's `session_store_pool_size=2, session_store_max_overflow=0` connection pool each use at most 8 of the 10 connections the `platform` stack's `max_connections` comment reserves for `ai`.

## Studio API token

`studio_token.tf` generates the shared bearer secret the harness's studio routes compare requests against (`harness.auth` in the `ai` repo), stores it as `dfo-dev-studio-api-token`, and mounts it on the service as `STUDIO_API_TOKEN`. Until that mount reaches a running revision, the harness accepts any non-empty bearer token and logs `STUDIO AUTH IS OPEN` at startup, on a public URL, so this is a gap being closed rather than a feature being added.

This is the interim scheme: #12's settled end-state for proxy-to-harness auth is a service-to-service ID token from the website proxy, with this service coming off public access, and this secret retires when that lands. The website services get their own mount of this secret in a later PR, once the proxy code reads it; humans who call the studio routes directly are granted read on this one secret through `var.studio_token_readers`, and fetch it with `just studio-token`. Rotation is bumping `studio_api_token_version`: the replacement version is created before the old one is destroyed, and the service's mount pins the version number rather than `latest`, so the same apply rolls a revision onto the new token and warm and new instances can never disagree.

## MCP API token

`mcp_token.tf` generates the shared bearer secret the harness's MCP mounts (`/mcp/data`, `/mcp/analysis`, `/mcp/presentation`) compare requests against, stores it as `dfo-dev-mcp-api-token`, and mounts it on the service as `MCP_API_TOKEN`. Unset, the harness mints a random token at startup for its own in-process clients only, so this mount is what lets callers outside the process — including the out-of-repo e2e test daemon that points at this service's deployed URL — reach the MCP mounts instead of drawing a `401`. Health routes are unaffected either way. [dfo-ai#190](https://github.com/ONEcampaign/dfo-ai/pull/190) owns the application change that puts the bearer gate on the three mounts and reads this variable.

Humans who call the MCP mounts directly, and whoever configures the e2e test daemon, are granted read on this one secret through `var.mcp_token_readers`. Rotation is bumping `mcp_api_token_version`: the replacement version is created before the old one is destroyed, and the service's mount pins the version number rather than `latest`, so the same apply rolls a revision onto the new token and warm and new instances can never disagree.

## Datasets first-party principal

This stack reads, rather than creates, the shared bearer value the Datasets publish door on `dfo-dev-apis` compares the `x-dfo-principal` header against: `var.datasets_first_party_principal_secret_id`, a plain value copied from the secret id `../apis/datasets_first_party_principal.tf` creates and pins its own mount to, not a `data "google_secret_manager_secret"` lookup — that would resolve against live state at plan time, and this stack's plan must not depend on the `apis` stack having applied first. See that stack's README for the interim framing and the exposure this value narrows but does not close. The pin door reads a separate value, generated in `../apis/datasets_pin_principal.tf`, that this stack does not mount or call. This stack mounts `DATASETS_FIRST_PARTY_PRINCIPAL`, which the harness's `PlatformAssembler` sends on the one outbound call that needs it, publishing an analysis frame to the Datasets API. Unset, that call refuses locally with `publish_not_configured` before it reaches the network.

The mount here reads `latest` rather than a pinned version, since this stack does not own the version resource. Rotating the secret in `apis` deletes the old version once the new one exists, but that apply rolls only the `apis` service; a running `ai` instance keeps whatever value it read at startup regardless of what Secret Manager now holds, and the next publish call through `PlatformAssembler` would then carry a value the door no longer accepts. Rolling this service — an image-only deploy, or a `terraform apply` here that changes the service — is what picks up the new version; a `terraform apply` with no other change is a no-op and creates no new revision.

## Live-refresh principal

`LIVE_REFRESH_PRINCIPAL` is the bearer value `POST /api/studio/refresh` compares the `Authorization: Bearer` header against. That endpoint redraws a derived card for a live Studio share without a conversation or a model, and the website calls it. It is separate from `STUDIO_API_TOKEN`. Unset or empty, the endpoint refuses every caller.

The secret is created and rotated in the `apis` stack, as `dfo-dev-live-refresh-principal`. This stack reads it through `var.live_refresh_principal_secret_id`, a plain value copied from that stack's secret id, because a `data "google_secret_manager_secret"` lookup would fail this stack's plan whenever the `apis` stack had not yet created the secret. When both stacks change in one merge, `apply.yml` applies `apis` first, since it lists `apis` as a producer stack.

The mount reads `latest`, so a rotation in `apis` reaches a running instance only on a new revision, which an image-only deploy or a `terraform apply` here that changes the service creates.

## Langfuse tracing

The harness exports traces to Langfuse Cloud EU when `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` and `LANGFUSE_BASE_URL` are all set. This stack mounts the first two from the existing `dfo-dev-langfuse-public-key` and `dfo-dev-langfuse-secret-key` Secret Manager secrets, which are not terraform-managed and are referenced through `data "google_secret_manager_secret"` sources like the Gemini key. `LANGFUSE_BASE_URL` is set to `https://cloud.langfuse.com`, the region the keys belong to. `LANGFUSE_TRACING_ENVIRONMENT` is set to `dfo-dev-ai`, so deployed traces filter apart from a local harness's, which export under Langfuse's default environment. The module grants the runtime service account `roles/secretmanager.secretAccessor` on each of the two secrets, in the same project as the service.

Both mounts read `latest`, since this stack does not own the version resources. Cloud Run resolves `latest` when an instance starts, so after a key rotation warm instances keep the key they started with. A rollout replaces them: an image-only deploy from `ai`'s CI, or a `terraform apply` here that changes the service.

After a rollout, `curl <service-url>/status/telemetry` returns `{"telemetry": "langfuse"}` when tracing is on. `off` means one of the three variables is missing or empty, or tracing is disabled, and the startup log says which. Google Frontend answers `/healthz` on Cloud Run, so use `/status/telemetry`.

A rejected key pair leaves the state `langfuse`. The harness's startup credentials check logs a warning. Traces are accepted once the secret holds a valid pair and the service is rolled. They appear in the Langfuse project under the environment `dfo-dev-ai`.

## Handoff after `apply`

`ai`'s deploy workflow reads `REGION`, `PROJECT_ID`, `AR_REPO` and `SERVICE_AI` as variables and `WIF_PROVIDER` and `WIF_SA` as secrets from its `dev` GitHub Environment. Each is an output of this stack or `foundation`, and `deploy_values` in `scripts/deploy-targets.sh` maps each name to its output.

Run **`just handoff ai`** (`scripts/handoff.sh dfo-dev ai`) after applying the `foundation` and `ai` stacks, and again after either renames a resource it hands over. It reads those outputs and sets them on `ai`'s `dev` GitHub Environment with `gh`, using your GitHub login. Nothing else sets them.

The script uses `gh` because a Terraform `integrations/github` resource would need a long-lived GitHub admin credential stored in Secret Manager, which defeats the keyless WIF design. `ai`'s `deploy/README.md` describes how its workflow uses each value.
