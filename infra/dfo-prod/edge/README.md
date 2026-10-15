# edge (prod)

The public edge for developmentfinance.org, in prod only. Cloudflare proxies the zone's records to a global external Application Load Balancer, which routes every request through a serverless network endpoint group to the `dfo-prod-website` Cloud Run service. The `.tf` files are symlinks to `infra/stacks/edge`. This directory holds prod's backend, tfvars, and lock file.

The load balancer listens on 443 only. Cloudflare's Always Use HTTPS redirects plain HTTP at the edge, and Cloudflare reaches the origin over HTTPS.

## Origin lock

The Cloud Armor policy `dfo-prod-edge` on the backend service denies every request with a 403 unless it carries the header `x-dfo-edge-auth` set to a shared secret. Cloudflare's Transform Rule adds that header to each request it forwards, so only traffic that passed Cloudflare's rate limit and Access rules reaches the website. A Cloudflare zone of someone else's, pointed at the load balancer's address, lacks the header and gets the 403.

The secret is a `random_password` in `origin_secret.tf`, held in the stack's state in the private state bucket. Anyone with `compute.securityPolicies.get` on `prod-fin-observatory` can also read it from the policy's rule expression. Whoever holds the value can reach the origin through a Cloudflare zone of their own, so rotate it if it leaks.

To send a request to the load balancer directly, bypassing Cloudflare, with the secret:

```bash
curl --resolve developmentfinance.org:443:"$(terraform output -raw lb_ipv4)" \
  -H "x-dfo-edge-auth: $(terraform output -raw origin_auth_header_value)" \
  https://developmentfinance.org/
```

## Rotating the origin secret

Bump `origin_auth_rotation` in `infra/stacks/edge/origin_secret.tf` and merge. The apply replaces the `random_password`, then rewrites the Cloud Armor rule and the Cloudflare Transform Rule in the same run. Between those two writes the origin expects one value and Cloudflare sends the other, so requests fail with a 403 for a few seconds. Rotate at a quiet hour.

## Certificate

Certificate Manager issues one managed certificate for `developmentfinance.org` and `*.developmentfinance.org`, which covers `www` and `preview`. The certificate map holds a single `PRIMARY` entry, so the proxy serves that certificate for any SNI. Cloudflare's SSL mode is Full (strict), so it validates this certificate on every request to the origin.

Google proves control of the domain through a DNS authorization of type `PER_PROJECT_RECORD`. Its CNAME lives at `_acme-challenge_<suffix>.developmentfinance.org`, given by the `dns_authorization_record` output. The stack creates it in Cloudflare, unproxied, in `cloudflare_dns.tf`. The fixed-record type would put the CNAME at `_acme-challenge.developmentfinance.org`, where Cloudflare's Universal SSL serves its own ACME TXT records, and Google requires the CNAME to be the only record at its name.

The certificate stays in `PROVISIONING` until Google sees the CNAME. Check that it is `ACTIVE` before sending traffic to the load balancer:

```bash
gcloud certificate-manager certificates describe dfo-prod-edge \
  --project prod-fin-observatory --format 'value(managed.state)'
```

## Cloudflare

The stack manages these parts of the `developmentfinance.org` zone. The token reaches the zone by the id in `cloudflare_zone_id`, so it needs no Zone Read lookup.

- DNS. The apex and `www` A records are imported. Both point at the holding page (`35.186.240.63`, the `devfinance-redirect-ip` load balancer in `one-data-commons`) while `serve_from_lb` is false, and at the load balancer once it is true. `preview.developmentfinance.org` and `mcp.developmentfinance.org` point at the load balancer. The two TXT records stay unmanaged.
- Origin auth, phase `http_request_late_transform`. Sets the origin secret header on requests to the apex, preview, and MCP hosts.
- Redirect, phase `http_request_dynamic_redirect`. Sends `www` to `https://developmentfinance.org` with a 301, keeping the path and query. On `mcp.developmentfinance.org`, every path that does not start with `/mcp` gets the same redirect, so `https://mcp.developmentfinance.org/mcp` serves the MCP endpoint and the host serves nothing else. The zone's existing empty ruleset in this phase is imported, because a zone holds one entrypoint ruleset per phase.
- Rate limit, phase `http_ratelimit`. Two rules, the Pro plan's limit, each counting per IP over 60 s and blocking for 10 minutes. An IP that sends more than `edge_studio_requests_per_minute` requests to a path starting `/api/v1/studio` or `/api/studio` is blocked from Studio. An IP that sends more than `edge_api_requests_per_minute` requests to any other path starting `/api/v1/`, `/api/search`, `/api/datasets`, or `/api/graph` is blocked from the data API. `/mcp` has no edge limit. Cloudflare counts per IP on this plan, and MCP connectors call from a few shared provider addresses, so a limit there would block all of a connector's users together. The harness caps `/mcp` tool calls per instance with `COMBINED_MCP_REQUESTS_PER_S` and `COMBINED_MCP_BURST`, set in `infra/stacks/ai/main.tf`.
- Managed WAF, phase `http_request_firewall_managed`. The Cloudflare Managed Ruleset runs at its default actions. The OWASP Core Ruleset runs at paranoia level 1 with its anomaly rule set to log, so a request scoring 40 or more appears in Security Events with the action Log and still reaches the origin. Review those events before changing the action to block.
- Access on the preview host. A zone-scoped self-hosted application with an inline allow policy for `preview_access_email_domains` and `preview_access_emails`, and a 24-hour session. It uses the account's Zero Trust organisation and identity providers, which the stack leaves alone.
  The preview host serves the production website, whose Better Auth origin is `BETTER_AUTH_URL` (the `website_url` tfvar). Sign-in and OAuth callbacks work only on that origin and fail on the preview host; browsing, search, downloads, and guest Studio work there.

A plan with the read-only token, as the `plan` environment runs in CI, prints `failed to make http request for the dry run ... 403` for the rulesets. This is expected, because Cloudflare's ruleset dry run needs write permission.

The first apply adopts the apex and `www` records and the redirect ruleset through the `import` blocks in `cloudflare_dns.tf` and `cloudflare_rules.tf`. Once state holds them, the blocks do nothing.

## Apply order

Edge applies after `foundation`, which grants the applier the load balancer, Cloud Armor, and Certificate Manager roles and lets it write this stack's state, and after `website`, whose Cloud Run service the endpoint group names. The stack enables `certificatemanager.googleapis.com` itself. The first apply can fail with `SERVICE_DISABLED` on the Certificate Manager resources while the API propagates. Recover with a `workflow_dispatch` of `apply.yml` with `stack=edge`. The same dispatch recovers an apply where the `apis` producer tier failed and skipped edge.

## Made by hand first

- A local backend init, `just ENV=dfo-prod STACK=edge bootstrap`, once `foundation` has applied.
- The Cloudflare API token, zone-scoped to developmentfinance.org. CI reads it from the `CLOUDFLARE_API_TOKEN` secret in the `production` (edit) and `plan` (read) environments. Locally, export it from the macOS keychain service `dfo-cloudflare-edge-apply` or `dfo-cloudflare-edge-plan` as `CLOUDFLARE_API_TOKEN`. The provider reads only that variable.
