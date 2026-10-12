# cloud-run-service

A reusable Cloud Run v2 service module: the service itself, a dedicated runtime service account, per-secret IAM grants, and a deployer `actAs` binding so an owning repo's CI can push image-only revision updates. Each consumer stack supplies its own image, env vars/secrets, and scaling config — the module owns the shape, not the workload.

Current consumers: `dfo-dev/ai` (the `dfo-ai` agent harness, see `../../dfo-dev/ai/README.md`), `dfo-dev/apis` (the dfo-apis Search API, see `../../dfo-dev/apis/README.md`), and `dfo-dev/website` (the dfo-website staging service, see `../../dfo-dev/website/README.md`).

## The image seam

The owning repo's CI, not Terraform, updates the running image after the first apply. That update is an image-only `gcloud run services update --image=...` call, never a full manifest replace, so it never fights this module for ownership of scaling, secrets, or service-account config. Terraform sets `var.bootstrap_image` (default `gcr.io/cloudrun/hello`) on first apply and then never touches the field again, via:

```hcl
lifecycle {
  ignore_changes = [
    template[0].containers[0].image,
    client,
    client_version,
  ]
}
```

`client` and `client_version` are ignored for the same reason as the image. `gcloud run services update` stamps them with its own name and version to record which tool last mutated the service, so they belong to whoever deployed last. Left unignored, every plan after a deploy proposes nulling them and every deploy sets them again, and the stack never plans clean.

## Sizing

Five inputs size each instance: `cpu` (default `"1"`), `memory` (default `"512Mi"`), `cpu_idle` (default `true`, throttles CPU between requests so billing tracks request-handling time), `startup_cpu_boost` (default `true`, trades a small startup CPU cost for a shorter cold start), and `timeout_seconds` (default `300`, the longest a single request may run before Cloud Run cancels it). Every consumer stack sets these explicitly at its `module` call, since traffic and workload shapes differ across services.

## Session affinity

`session_affinity` (default `false`) routes a client's repeat requests to the same instance for a consumer that keeps per-client state in memory. Cloud Run treats it as best-effort, so the consumer must still tolerate a request landing on another instance.

## Service-level instance cap

`max_instances` bounds each revision independently. During a rollout, the old and new revisions each scale up to that count on their own, so the combined instance total can reach twice `max_instances`. `var.service_max_instances` (default `null`) sets the top-level `scaling.max_instance_count` instead, a combined ceiling Cloud Run distributes across whatever revisions are receiving traffic in proportion to their traffic split, so old and new share one instance budget during a rollout. Null, the default, omits the top-level block and leaves every consumer's revision-level-only behavior unchanged. `apis` and `website` set it to `5` and `ai` to `2`, the totals the platform stack's `max_connections` budget counts (`../../stacks/platform/main.tf`).

## Ordering a revision on out-of-module resources

`var.readiness_dependencies` (default `[]`) takes a list of ids and writes them into a `google_cloud_run_v2_service` template annotation, an unstructured metadata field with no effect on the running container. Its purpose is entirely in Terraform's dependency graph. Passing a resource's id here makes the revision wait for that resource, for a resource this module has no other reason to reference (no env var, secret, or VPC input touches it). A `depends_on` on the whole `module` block would work in the direction "module resources wait on this stack's other resources" only when nothing in that stack's other resources already depends on an output of the module. `ai`'s IAM grants read `runtime_service_account_email`, which the module's own `google_service_account.runtime` produces, so a module-level `depends_on` pointing back at those grants closes a cycle. Threading the ids through a variable keeps the edge one-directional. Only the service resource that receives the annotation waits, not the service account or any other resource inside the module.

## Runtime service account

The module creates a dedicated, least-privilege runtime service account (`<service_name>-run`), distinct from any CI/deployer service account. It is granted `roles/secretmanager.secretAccessor` on exactly the secrets referenced via `secret_env_vars`, never a project-level grant, and nothing else. No `run.developer`, no `artifactregistry.*`. Those belong to the deployer identity, not the runtime one.

## Direct VPC egress

`var.vpc_access` (`{ network, subnetwork }`, default `null`) puts the service on a consumer's own subnet for direct VPC egress — the shape a service needs to reach the shared Cloud SQL instance in `dfo-dev/platform` over a `consumer-psc-network` subnet (see that module's README) rather than over the public internet. Null, the default, configures no VPC access at all; `ai` wants that and leaves the input unset.

Egress is hardcoded to `PRIVATE_RANGES_ONLY` inside the module, not exposed as part of `var.vpc_access`: the `consumer-psc-network` subnets this input points at deliberately have no NAT gateway, so `ALL_TRAFFIC` would route every outbound call — including calls to public APIs like Gemini or the Data Commons graph — onto a network with no path out. `PRIVATE_RANGES_ONLY` sends only RFC 1918 destinations (the PSC endpoint among them) over the VPC and leaves everything else on the service's normal public path.

`apis` (`../../dfo-dev/apis/network.tf`) and the `website` staging service (`../../dfo-dev/website/main.tf`) are the callers today, wiring their `consumer-psc-network` instantiation's `network_id`/`subnetwork_id` outputs straight through.

## Why a module

Written as a module (not inlined in a stack) so multiple stacks and future environments (e.g. `dfo-prod`) can instantiate the same Cloud Run service shape unchanged, varying only the input variables.
