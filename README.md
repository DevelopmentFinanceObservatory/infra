# DFO infrastructure

Terraform for the Google Cloud infrastructure of the [Development Finance Observatory](https://github.com/DevelopmentFinanceObservatory) (DFO). It defines the Cloud Run services, databases, storage, networking and access rules behind the platform. Each environment and stack is its own Terraform root with its own state.

The DFO is an initiative of [ONE Data](https://data.one.org), built on [Google Data Commons](https://datacommons.org). This repository is where the other [DFO repositories](https://github.com/DevelopmentFinanceObservatory) get somewhere to run.

This repository is under active development. Interfaces, schemas, and data may change without notice.

## What's inside

```text
infra/
├── modules/        # reusable modules shared by the stacks
├── stacks/         # Terraform source for each stack, shared by both environments
├── dfo-dev/        # dev environment: one Terraform root (own state) per stack
│   ├── dcp/
│   ├── foundation/
│   ├── ai/
│   ├── apis/
│   ├── pipelines/
│   ├── platform/
│   └── website/
└── dfo-prod/       # prod environment: the same stacks except pipelines, plus the public edge
    └── edge/
scripts/            # helpers for CI, GitHub setup and the dcp stack
justfile            # task runner recipes (run `just` to list them)
```

A change to one stack appears only in that stack's plan. The stacks are:

- [dcp](infra/dfo-dev/dcp): the Data Commons Platform. The upstream stack module (services, Spanner, Redis, ingestion) plus DFO additions in `dfo.tf`. The `dcp` repository's CI builds images and opens an auto-merged pull request that pins them here.
- [edge](infra/dfo-prod/edge): prod only. The load balancer and certificate for developmentfinance.org, the Cloud Armor policy that admits only Cloudflare, and the Cloudflare zone's DNS and rules.
- [foundation](infra/dfo-dev/foundation): shared plumbing. Artifact Registry, Workload Identity Federation, and the deployer service accounts.
- [ai](infra/dfo-dev/ai): the AI service (agent harness and MCP servers). The `ai` repository's CI deploys images onto it.
- [apis](infra/dfo-dev/apis): the Search and Datasets APIs on one Cloud Run service, with the storage, database and private-network access the Datasets API needs. The `apis` repository's CI deploys images onto it.
- [pipelines](infra/dfo-dev/pipelines): storage for the data pipelines, which the `pipelines` repository reads and writes.
- [platform](infra/dfo-dev/platform): the shared Cloud SQL Postgres instance, reached over Private Service Connect. Each tenant's database and users live in the tenant's own stack.
- [website](infra/dfo-dev/website): the DFO website's Cloud Run service, plus its private network path to the shared Postgres instance. The `website` repository's CI deploys images onto it.

Each stack's README says what belongs in it.

## Getting started

Planning and applying need access to ONE's Google Cloud projects (`dev-fin-observatory` and `prod-fin-observatory`), which only the ONE Data team holds. Without it you can read the code and run the checks that need no credentials. You need [just](https://github.com/casey/just), [Terraform](https://developer.hashicorp.com/terraform/install) 1.5 or later, and [uv](https://docs.astral.sh/uv/).

```bash
just install                # install the pre-commit hooks
just fmt                    # terraform fmt across infra/
just check                  # run every pre-commit hook
cd infra/dfo-dev/dcp && terraform init -backend=false && terraform validate
```

With access, `just auth` signs in to `gcloud`, `just bootstrap` runs `terraform init` for the `dcp` stack, and `just plan` previews its changes. Select another stack or environment with `STACK=` and `ENV=`, for example `just STACK=foundation plan`.

## How changes ship

Pull requests target `dev`. CI posts a `terraform plan` for each changed stack as a pull request comment, and merging to `dev` applies the change to the dev environment. A release is a pull request from `dev` into `main`, which deploys prod after a maintainer approves it. The full flow, the destroy guard and the break-glass path are in [docs/development.md](docs/development.md).

## Documentation

- [docs/development.md](docs/development.md): CI, releases, state, wiring a service repository, and operating the dcp stack.
- [infra/dfo-dev/dcp/dfo.README.md](infra/dfo-dev/dcp/dfo.README.md): which dcp files the upstream CLI generates and which belong to DFO.
- [infra/modules](infra/modules/README.md): the shared modules.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Licence

MIT. See [LICENSE](LICENSE).
