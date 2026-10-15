# website (prod)

Prod's copy of the website stack: the `dfo-prod-website` Cloud Run service, its database on the shared Cloud SQL instance, its IAM migrator, and the `dfo-prod-website-migrate` Job. The `.tf` files are symlinks to `infra/stacks/website`; `infra/dfo-dev/website/README.md` describes what they build. This directory holds prod's backend, tfvars, and lock file.

## Apply order

Website applies last, after `foundation`, `platform`, `dcp`, `apis`, and `ai`. It reads the `apis` stack's `dfo-prod-datasets-pin-principal` secret and the `ai` stack's `dfo-prod-studio-api-token` and `dfo-prod-mcp-api-token` secrets, and plan fails until they exist. It also grants its runtime account `roles/run.invoker` on `dfo-prod-apis`, so apply fails until that service exists. The commented lines in `env.auto.tfvars` take values from those stacks' outputs.

## Made by hand first

The six sign-in secrets, each with at least one version, since a secret with no version passes plan and then stops the revision from starting:

- `dfo-prod-website-google-client-id` and `-google-client-secret`, from a Google OAuth client registered in `prod-fin-observatory`.
- `dfo-prod-website-github-client-id` and `-github-client-secret`, from the DevelopmentFinanceObservatory org's GitHub OAuth App.
- `dfo-prod-website-microsoft-client-id` and `-microsoft-client-secret`, from the Entra app.

Each OAuth client's callback must name the origin set in `website_url`.

## Feedback Slack webhook

The stack creates `dfo-prod-website-feedback-slack-webhook` with a first version holding the literal `disabled`, which the app reads as "notifications off". Feedback submitted on the site then returns 200 and never reaches Slack, so after the first apply add the Slack incoming webhook URL as a new version. Prod posts to the same channel as staging, so the URL is the one in `dfo-dev-website-staging-feedback-slack-webhook`:

```
printf '%s' 'https://hooks.slack.com/services/…' | gcloud secrets versions add \
  dfo-prod-website-feedback-slack-webhook \
  --project prod-fin-observatory --data-file=-
```

The service mounts `latest`, but running instances keep the value they started with, and `min_instances = 1` keeps one running. Roll a new revision by dispatching the website's production deploy:

```
gh workflow run deploy-prod.yml -R DevelopmentFinanceObservatory/website --ref main
```

`infra/dfo-dev/website/README.md` explains the placeholder and rotation in full.
