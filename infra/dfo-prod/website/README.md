# website (prod)

Prod's copy of the website stack: the `dfo-prod-website` Cloud Run service, its database on the shared Cloud SQL instance, its IAM migrator, the `dfo-prod-website-migrate` Job, the `dfo-prod-website-export` event export Job with its `website_export` dataset, the `dfo-prod-website-share-migrate` share migration Job, and the `dfo-prod-website-library-share-check` Library share check Job with its daily trigger and alert. The `.tf` files are symlinks to `infra/stacks/website`; `infra/dfo-dev/website/README.md` describes what they build. This directory holds prod's backend, tfvars, and lock file.

## Apply order

Website applies last, after `foundation`, `platform`, `dcp`, `apis`, and `ai`. It reads the `apis` stack's `dfo-prod-datasets-pin-principal` secret and the `ai` stack's `dfo-prod-studio-api-token` and `dfo-prod-mcp-api-token` secrets, and plan fails until they exist. It also grants its runtime account `roles/run.invoker` on `dfo-prod-apis`, so apply fails until that service exists. The service also mounts the `apis` stack's `dfo-prod-live-refresh-principal`, `dfo-prod-caller-principal`, and `dfo-prod-caller-hmac-key`, and a revision fails to start until they exist. The caller HMAC key was this stack's `dfo-prod-website-caller-hmac-key` until it moved to `apis`, and the apply that destroys the old secret here needs the `allow-destroy` label on its pull request. The new key is a fresh value, so every visitor's `ip:` caller id changes once. After a rotation in `apis`, this service keeps the old key until it takes a new revision. The commented lines in `env.auto.tfvars` take values from those stacks' outputs.

The service also mounts `dfo-prod-website-export-hmac-key` as `EXPORT_ID_HMAC_KEY`, pinned to the version the export Job uses. The app HMACs the user id with it into the `x-dfo-account` header it sends the Studio harness, and the export Job hashes user ids with the same key. Rotating it (`website_export_hmac_key_version`) changes every exported user hash and every Studio account digest together.

## Made by hand first

The six sign-in secrets, each with at least one version, since a secret with no version passes plan and then stops the revision from starting:

- `dfo-prod-website-google-client-id` and `-google-client-secret`, from a Google OAuth client registered in `prod-fin-observatory`.
- `dfo-prod-website-github-client-id` and `-github-client-secret`, from the DevelopmentFinanceObservatory org's GitHub OAuth App.
- `dfo-prod-website-microsoft-client-id` and `-microsoft-client-secret`, from the Entra app.

Each OAuth client's callback must name the origin set in `website_url`.

## Rolling onto a new revision

A secret mounted at `latest` resolves when an instance starts, and `min_instances = 1` keeps one instance running on the value it started with. Roll every instance onto a new secret version in seconds by changing a label:

```
gcloud run services update dfo-prod-website --project prod-fin-observatory \
  --region europe-west1 --update-labels=rolled-at=$(date +%Y%m%d%H%M%S)
```

A production deploy (`deploy-prod.yml`) also rolls a revision, but it builds the image, runs the migration job and waits for reviewer approval. `infra/dfo-dev/website/README.md` ("Rolling onto a new revision") explains the label and why Terraform leaves it alone.

## Feedback Slack webhook

The stack creates `dfo-prod-website-feedback-slack-webhook` with a first version holding the literal `disabled`, which the app reads as "notifications off". Feedback submitted on the site then returns 200 and never reaches Slack, so after the first apply add the Slack incoming webhook URL as a new version. Prod posts to the same channel as staging, so the URL is the one in `dfo-dev-website-staging-feedback-slack-webhook`:

```
printf '%s' 'https://hooks.slack.com/services/…' | gcloud secrets versions add \
  dfo-prod-website-feedback-slack-webhook \
  --project prod-fin-observatory --data-file=-
```

Then roll the service onto a new revision (see "Rolling onto a new revision").

`infra/dfo-dev/website/README.md` explains the placeholder and rotation in full.

## Graph Explorer readers

`GRAPH_EXPLORER_EMAIL_DOMAINS` is `var.graph_explorer_email_domains` joined with commas: the email domains whose verified accounts may open the Graph Explorer. An empty list admits nobody.

`LIBRARY_ENABLED` is `var.library_enabled` as `true` or `false`. While false, the Library at `/library` answers 404 to everyone except Library admins (`ADMIN_EMAILS`), who can publish to it from the Studio and open its pages to build its content. The footer and the sitemap leave it out. Setting it to true makes the Library public on the next apply, with no website rebuild.

`STUDIO_ROUTING_ENABLED` is `var.studio_routing_enabled` as `true` or `false`. While true, Get Data sends `studio_routing` with each typed question, and the search API's Studio router can move a question that needs analysis into Studio or offer Studio beside the data. The search API refuses that field until it serves it, so set the variable true only where that API is live, and false before rolling the API back past it. An unset value is off.

## Admin emails

The stack creates `dfo-prod-website-admin-emails` with a first version holding the literal `none`, which is not an email address, so nobody is an admin and `/admin/api-keys` answers 404. The list is private, so it lives only in Secret Manager. The mount is pinned to `admin_emails_version` in `env.auto.tfvars`, which starts at that first version, so each list change made through Terraform reaches prod through the apply of a reviewed release pull request. The pin is a version number, which reveals no address, so the reviewer reads the version it names with `gcloud secrets versions access N --secret dfo-prod-website-admin-emails --project prod-fin-observatory` before approving. Anyone with `run.services.update` on the service can still point the mount at any version outside Terraform, until the next apply reverts it. To change the list, add a version holding every admin. The prompt keeps the list off the screen and out of shell history, and the command prints the new version's name, which ends in its number. The runtime account's `secretAccessor` on the secret comes from the `cloud-run-service` module:

```
read -rs ADMINS; printf '%s' "$ADMINS" | gcloud secrets versions add dfo-prod-website-admin-emails \
  --project prod-fin-observatory --data-file=- --format='value(name)'
```

Then set `admin_emails_version` in `infra/dfo-prod/website/env.auto.tfvars` to that number in a pull request, and release it to main. Its apply rolls a new revision, the warm instance included, so no label roll is needed. A removal also takes effect only at that apply, so release it promptly when an admin must lose the page. `infra/dfo-dev/website/README.md` ("Admin emails") explains the mount in full.

## API key tag secrets

The stack creates `dfo-prod-website-api-key-tag-secrets` and generates its first version (`api_key_tag_secrets.tf`), so API keys work from the first apply and the value never lands in Terraform state. A production revision refuses to start without it, so apply this before deploying a website that issues keys.

The mount is pinned to `api_key_tag_secrets_version` in `env.auto.tfvars`, so each version reaches prod through the apply of a release pull request. Rotate in three steps: add a version holding `old,new` and move the pin to it; once the step-1 revision serves all traffic, add one holding `new,old` and move the pin again; once every key the old secret signed is replaced, add one holding the new secret alone and move the pin. Once step 2 is live, never roll traffic back to a revision older than step 1: it knows only the old secret, so every key signed since step 2 fails there. `infra/dfo-dev/website/README.md` ("API key tag secrets") gives the commands, with `SECRET=dfo-prod-website-api-key-tag-secrets` and `PROJECT=prod-fin-observatory`, and the traffic check with `dfo-prod-website` in `europe-west1`.

## Email sign-in

The stack creates `dfo-prod-website-turnstile-secret-key` with a first version holding a single space, which the app reads as blank, so email sign-in stays off. The Turnstile widget is "DFO website production" in the ONE Campaign Cloudflare account, for `developmentfinance.org` and its subdomains. `env.auto.tfvars` holds its site key as `turnstile_site_key`. Add its secret key as a new version with `read -rs KEY; printf '%s' "$KEY" | gcloud secrets versions add dfo-prod-website-turnstile-secret-key --project prod-fin-observatory --data-file=-`. Mail goes through the role `development-finance-observatory-ses-sender-production` in ONE's SES account, which trusts only `dfo-prod-website-run@prod-fin-observatory.iam.gserviceaccount.com` with the token audience `development-finance-observatory-production`. `env.auto.tfvars` sets both in `ses`. The apply for any tfvars change creates a new revision. A new secret version needs a roll (see "Rolling onto a new revision").

`infra/dfo-dev/website/README.md` describes all four settings and the role's trust in full.

## Event export

`env.auto.tfvars` sets `event_export_enabled = true` (`infra/dfo-dev/website/README.md`, "Event export"). Apply this stack before the dfo-website deploy that carries the migration granting `SELECT` on `event` to `website_export_reader`, since that migration fails while the role is missing. Then run `scripts/handoff.sh dfo-prod website`, which writes `EXPORT_JOB_WEBSITE`, so the deploy moves the Job to the website image.

## Internal engineering accounts

The stack creates `dfo-prod-website-internal-eng-emails` with a first version holding the literal `none`, which marks nobody, so every event carries `internal_eng: false` until the real list is added. The list names staff, so it never appears in this repository. After the prod apply, add the list as a new version holding every entry, then roll a new revision with the label roll in "Rolling onto a new revision", since running instances keep the value they started with and `min_instances = 1` keeps one running. A list change reaches new events only. The entries below are placeholders:

```
printf '%s' 'eng@example.org,example.net' | gcloud secrets versions add dfo-prod-website-internal-eng-emails \
  --project prod-fin-observatory --data-file=-
```

Dispatching the website's production deploy (`gh workflow run deploy-prod.yml -R DevelopmentFinanceObservatory/website --ref main`) also rolls a revision. `infra/dfo-dev/website/README.md` ("Internal engineering accounts") explains the mount and the list format in full.

## Share migration

The Job `dfo-prod-website-share-migrate` moves the website's `share` rows into dfo-apis's Presentation store once ("Share migration" in `infra/dfo-dev/website/README.md`). Apply `apis` first, since this stack grants the runtime account read on `dfo-prod-share-import-principal`, then run `scripts/handoff.sh dfo-prod website`, which writes `SHARE_MIGRATE_JOB_WEBSITE`, so the deploy moves the Job to the website image. Once dfo-apis serves the share import route and that deploy has moved the image, run:

```bash
gcloud run jobs execute dfo-prod-website-share-migrate \
  --region=europe-west1 --project=prod-fin-observatory --wait
```

On exit 1, read the `share <id>:` lines in the execution's logs, fix the cause, and run it again. Then run `normalise-recipes` on `dfo-prod-datasets-maintenance` (see the `apis` stack's README). The Job, the import route and its principal are removed once prod's shares are migrated.

## Library share check

The Job `dfo-prod-website-library-share-check` reads every published Library artifact's share from dfo-apis daily at 06:00 UTC ("Library share check" in `infra/dfo-dev/website/README.md`). Its alert policies, "Library share check failed on dfo-prod-website" and "Library share check not running on dfo-prod-website", notify `Telemetry pipeline alerts: team`, the channel the `apis` stack's alerts use, set as `alert_notification_channel` in `env.auto.tfvars`. After the apply, run `scripts/handoff.sh dfo-prod website`, which writes `LIBRARY_SHARE_CHECK_JOB_WEBSITE`, so the next deploy moves the Job to the website image. Until then each daily run fails on the bootstrap image and opens the failure alert, and the not-running alert stays open until the first execution completes.

The service mounts `dfo-prod-typesafe-api-key`, the hand-made secret the `apis` stack's search binder reads, as `TYPESAFE_API_KEY`, and plan fails while the secret is missing. The service starts without a working key, so this stack need not apply before a website release, but the Library cannot publish until the key works. While it does not, the policy "Library publishing closed on dfo-prod-website" (`library_evergreen_alert.tf`) opens on each `library_evergreen_unavailable` line and notifies the same channel as the share check.
