# website (prod)

Prod's copy of the website stack: the `dfo-prod-website` Cloud Run service, its database on the shared Cloud SQL instance, its IAM migrator, and the `dfo-prod-website-migrate` Job. The `.tf` files are symlinks to `infra/stacks/website`; `infra/dfo-dev/website/README.md` describes what they build. This directory holds prod's backend, tfvars, and lock file.

## Apply order

Website applies last, after `foundation`, `platform`, `dcp`, `apis`, and `ai`. It reads the `apis` stack's `dfo-prod-datasets-pin-principal` secret and the `ai` stack's `dfo-prod-studio-api-token` and `dfo-prod-mcp-api-token` secrets, and plan fails until they exist. The commented lines in `env.auto.tfvars` take values from those stacks' outputs.

## Made by hand first

The six sign-in secrets, each with at least one version, since a secret with no version passes plan and then stops the revision from starting:

- `dfo-prod-website-google-client-id` and `-google-client-secret`, from a Google OAuth client registered in `prod-fin-observatory`.
- `dfo-prod-website-github-client-id` and `-github-client-secret`, from the DevelopmentFinanceObservatory org's GitHub OAuth App.
- `dfo-prod-website-microsoft-client-id` and `-microsoft-client-secret`, from the Entra app.

Each OAuth client's callback must name the origin set in `website_url`.
