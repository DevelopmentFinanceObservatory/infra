# website (prod)

Prod's copy of the website stack: the `dfo-prod-website` Cloud Run service, its database on the shared Cloud SQL instance, its IAM migrator, the `dfo-prod-website-migrate` Job, and the `dfo-prod-website-export` event export Job with its `website_export` dataset. The `.tf` files are symlinks to `infra/stacks/website`; `infra/dfo-dev/website/README.md` describes what they build. This directory holds prod's backend, tfvars, and lock file.

## Apply order

Website applies last, after `foundation`, `platform`, `dcp`, `apis`, and `ai`. It reads the `apis` stack's `dfo-prod-datasets-pin-principal` secret and the `ai` stack's `dfo-prod-studio-api-token` and `dfo-prod-mcp-api-token` secrets, and plan fails until they exist. It also grants its runtime account `roles/run.invoker` on `dfo-prod-apis`, so apply fails until that service exists. The service also mounts the `apis` stack's `dfo-prod-live-refresh-principal`, `dfo-prod-caller-principal`, and `dfo-prod-caller-hmac-key`, and a revision fails to start until they exist. The caller HMAC key was this stack's `dfo-prod-website-caller-hmac-key` until it moved to `apis`, and the apply that destroys the old secret here needs the `allow-destroy` label on its pull request. The new key is a fresh value, so every visitor's `ip:` caller id changes once. After a rotation in `apis`, this service keeps the old key until it takes a new revision. The commented lines in `env.auto.tfvars` take values from those stacks' outputs.

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

## Email sign-in

The stack creates `dfo-prod-website-turnstile-secret-key` with a first version holding a single space, which the app reads as blank, so email sign-in stays off. The Turnstile widget is "DFO website production" in the ONE Campaign Cloudflare account, for `developmentfinance.org` and its subdomains. `env.auto.tfvars` holds its site key as `turnstile_site_key`. Add its secret key as a new version with `read -rs KEY; printf '%s' "$KEY" | gcloud secrets versions add dfo-prod-website-turnstile-secret-key --project prod-fin-observatory --data-file=-`. Mail goes through the role `development-finance-observatory-ses-sender-production` in ONE's SES account, which trusts only `dfo-prod-website-run@prod-fin-observatory.iam.gserviceaccount.com` with the token audience `development-finance-observatory-production`. `env.auto.tfvars` sets both in `ses`. The apply for any tfvars change creates a new revision. A new secret version needs a manual roll:

```
gh workflow run deploy-prod.yml -R DevelopmentFinanceObservatory/website --ref main
```

`infra/dfo-dev/website/README.md` describes all four settings and the role's trust in full.

## Event export

`env.auto.tfvars` sets `event_export_enabled = true` (`infra/dfo-dev/website/README.md`, "Event export"). Apply this stack before the dfo-website deploy that carries the migration granting `SELECT` on `event` to `website_export_reader`, since that migration fails while the role is missing. Then run `scripts/handoff.sh dfo-prod website`, which writes `EXPORT_JOB_WEBSITE`, so the deploy moves the Job to the website image.
