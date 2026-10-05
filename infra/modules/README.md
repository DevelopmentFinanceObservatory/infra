# modules — DFO-owned reusable Terraform modules

Modules shared across environments live here. Environment stacks under `infra/<env>/` instantiate them.

- `github-deployer/` — WIF deployer SA + impersonation binding (scoped to the repo by default, or narrowed to one git ref or one GitHub Environment) + role grants, project-wide or Artifact-Registry-repository-scoped, for one repo's GitHub Actions. Instantiated per repo by `dfo-dev/foundation` (see `../dfo-dev/foundation/README.md`). Does not own the WIF pool/provider itself.
- `cloud-run-service/` — Cloud Run service + dedicated runtime SA + per-secret IAM grants, with an image seam that lets the owning repo's CI own image updates. Instantiated by `dfo-dev/ai` and `dfo-dev/apis` (see `../dfo-dev/ai/README.md` and `../dfo-dev/apis/README.md`).
- `consumer-psc-network/` — a consumer's dedicated VPC, subnet, reserved address, Private Service Connect endpoint, and private DNS zone against the shared Cloud SQL instance in `dfo-dev/platform`. Instantiated by `dfo-dev/apis` and `dfo-dev/website` (see each stack's README, and the module's own README for the subnet range assignment).
