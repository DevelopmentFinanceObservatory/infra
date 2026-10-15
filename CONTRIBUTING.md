# Contributing

Issues and pull requests are welcome. The ONE Data team maintains this repository and applies its changes to Google Cloud, so open an issue to discuss a large change before you write it.

Contributors are expected to follow the [Code of Conduct](https://github.com/DevelopmentFinanceObservatory/.github/blob/main/CODE_OF_CONDUCT.md). Report security problems through GitHub private vulnerability reporting (the "Report a vulnerability" button under the Security tab), as the [security policy](https://github.com/DevelopmentFinanceObservatory/.github/blob/main/SECURITY.md) describes. For other questions, see [SUPPORT.md](https://github.com/DevelopmentFinanceObservatory/.github/blob/main/SUPPORT.md).

## Set up

You need [just](https://github.com/casey/just), [Terraform](https://developer.hashicorp.com/terraform/install) 1.5 or later, and [uv](https://docs.astral.sh/uv/).

```bash
just install
```

This installs the Python tooling and the pre-commit hooks. Nothing else in this repository runs without access to ONE's Google Cloud projects, so `terraform plan` and `terraform apply` are for maintainers.

## Before you open a pull request

```bash
just fmt
just check
cd infra/<env>/<stack> && terraform init -backend=false && terraform validate
```

`just fmt` formats every stack with `terraform fmt`, and CI fails a pull request whose `infra/` tree is not formatted. `just check` runs every pre-commit hook: ruff, codespell, actionlint, mdformat for Markdown, and file hygiene checks. Run `terraform validate` in each stack you changed. After changing a script in `scripts/`, run its `scripts/<name>.test.sh` where one exists. The tests use a stub `gh` and need no credentials.

## Branches and commits

Branch from `dev` and open the pull request against `dev`. `main` holds what runs in prod and only receives release pull requests from `dev`, which maintainers open. Merging to `dev` applies the change to the dev environment, so a maintainer reviews every pull request first.

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org), as in `feat(ci): choose the Terraform environment by branch` or `docs: describe the one-org setup`.

## What a pull request needs

- CI passes. `terraform fmt check` and `Changed stacks planned` are required on `dev`.
- The README of any stack you change describes it accurately, and `docs/development.md` matches any change to CI, releases or scripts.
- A change that would delete or replace a stateful resource (a database, a bucket, a secret) carries the `allow-destroy` label, which a maintainer applies after review.

The plan job needs a Google Cloud token, which GitHub withholds from pull requests opened from a fork. For a fork, a maintainer pushes your branch to this repository to get the plan.

## Maintainer notes

[docs/development.md](docs/development.md) covers CI, releases, Terraform state, and operating the dcp stack.
