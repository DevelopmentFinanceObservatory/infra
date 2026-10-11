# platform — shared Cloud SQL Postgres instance

One Postgres instance for the environment, shared by several components that each take one database inside it. The instance is the billed, backed-up server. A database is a namespace within it, and Postgres blocks cross-database queries without `dblink` or an FDW, so sharing the server never lets one tenant read another's tables. Each database gets its own user with no cross-database grants, and could later move out with a `pg_dump` and a connection-string change.

The instance serves several components and belongs to none of them, so it owns its own stack rather than sitting inside a tenant's. No tenant's teardown can take another tenant's data with it.

## Tenants

- **`website`** (`dfo-website`): accounts, saved views, share links. One database, `website-staging`, provisioned in the `website` stack against this instance.
- **`ai`** (`dfo-ai`): ADK session storage for the harness, self-migrating over its own connection, which is why it is not folded into the website database (#155).
- **`datasets`** (Datasets API): the spec registry, version records, artifact inventory, pin and share reference rows, audit events. Its database and users are provisioned in the `dcp` stack against this instance.
- **`analysis`**: the Analysis Toolkit handle store, if its lifecycle needs durability.

Each tenant's database and per-database users live in that tenant's own stack, not this one.

## Shape

- **PostgreSQL 18**, Enterprise edition, `db-custom-1-3840`. One dedicated vCPU and 3.75 GB, carrying Google's standard SLA. Prod runs `db-custom-2-7680`, two vCPUs and 7.5 GB, from its own `env.auto.tfvars`. Both are zonal, with no standby in a second zone.
- **No public IP, no VPC.** The instance publishes a Private Service Connect service attachment (`psc_service_attachment_uri` output) and authorises consumer projects (`allowed_consumer_projects`). Each consumer creates its own endpoint against that attachment in its own stack. Both ends have to agree, the authorisation here and the endpoint there, before a consumer can reach the instance.
- **IAM database authentication on.** Each service connects as itself, with no password to store or rotate. Built-in users stay enabled for migrations.
- **Daily automated backups and point-in-time recovery.**
- **`max_connections` set to 200** (`var.max_connections`), pinned explicitly so the budget stays fixed through a future tier change; prod sets 300 in its own `env.auto.tfvars`. The worst-case budget is 165: 60 for apis (a Datasets pool of 10 and a Presentation pool of 2 on each of 5 instances), 40 for the Datasets worker (10 on each of 4), 25 for website (5 on each of 5), 20 for ai (10 on each of 2, #155), 10 for the datasets-maintenance Job, and 10 in reserve for migrations and the built-in users. Each service's instance count is a service-level cap, which holds across old and new revisions during a rollout. `../../stacks/platform/main.tf` carries the same sum beside the flag.
- **Query Insights on** for every database on the instance, aggregating statistics, text, and plans for every query, plus per-application tags. Client addresses stay unrecorded, since Cloud SQL rejects that option on a PSC instance.

## Deletion protection is two flags

`deletion_protection` (Terraform-side) and `settings.deletion_protection_enabled` (API-side) both guard this instance. The API-side flag survives a config edit that drops the Terraform-side one, so recreating the instance takes two applies, the first to clear both flags and the second to destroy and recreate.

## How consumers read this stack's outputs

`instance_name`, `connection_name`, and `psc_service_attachment_uri` are published as plain outputs. Consumer stacks copy these into their own tfvars as literal values rather than reading them through `terraform_remote_state`, so a consumer's plan never depends on this stack having applied.

## The Cloud SQL Data API and the applier's database identity

`data_api_access = ALLOW_DATA_API` lets `google_sql_provision_script` run SQL against a tenant's database over the Admin API, with no network path to this PSC-only instance required — how a tenant stack applies something like a `REVOKE`/`GRANT` on its own database from CI. The script always runs as whatever identity calls it, which for every stack in this repo is `dfo-infra-applier`, so this stack creates that identity's Cloud SQL IAM database user (`google_sql_user.applier`, published as `applier_db_user`) next to the instance, the same way `postgres` is instance-level rather than tenant-level.

A freshly created IAM database user starts with no privileges at all — unlike a built-in user, it is not granted `cloudsqlsuperuser` automatically. A provision script needs to run REVOKE/GRANT against a database it doesn't own, which needs either that database's owner or a superuser, and the instance is PSC-only with no way to open a superuser session over the wire to grant a narrower role instead. `google_sql_user.applier` grants `cloudsqlsuperuser` directly (`database_roles`) for exactly that reason: it's what lets this stack bootstrap its own tenant provision scripts, for `datasets` and every tenant database that lands here after it, with no manual step in between.

That grant also means the applier can read every database on the shared instance through the Data API, not just the one it's provisioning. It doesn't open a new boundary — the applier already holds `roles/cloudsql.admin` and `roles/secretmanager.admin` project-wide, so it can already drop any of these databases, reset the `postgres` password, and read the migrator password out of Secret Manager — but it does thin further what was already a thin one.

## Revoking PUBLIC's CONNECT on `postgres`

`postgres` is the instance's own database rather than a tenant's, so its ACL is owned in this stack (`google_sql_provision_script.postgres_revoke_public_connect`). Each tenant database carries its own copy of the same revoke in its own stack, scoped to its own database.

The applier's CONNECT on `postgres` rests on an explicit grant made in the same script rather than on PUBLIC or on inherited ownership. `postgres` is the database every provision script in this repo connects to, so that grant runs ahead of the revoke, giving the applier a path into `postgres` that survives PUBLIC losing CONNECT.

The revoke removes only PUBLIC's entry, so any identity that holds a database role granting access to `postgres` still reaches it through that role. `cloudsqlsuperuser` is one such role, and Cloud SQL auto-grants it to every `BUILT_IN` user. The `datasets_migrator` user declared in the `dcp` stack is `BUILT_IN`, so it keeps its path into `postgres` after this revoke. The identity this revoke actually blocks is the Datasets API's runtime user (`datasets_runtime` in the `apis` stack), which holds no database roles at all and has no path into `postgres` once PUBLIC loses CONNECT.

That grant is a raw SQL side effect tracked only by this provision script, which re-runs only when its `script` string changes. If `google_sql_user.applier` were ever replaced, the new role would get `cloudsqlsuperuser` back from its own resource definition but would not get this explicit CONNECT grant reissued, since nothing about a user replacement changes the script string. `deletion_policy = "ABANDON"` on `google_sql_user.applier` is what keeps that replacement from happening as a side effect of an unrelated change. Anyone who deliberately replaces the applier user should re-run this stack's provision script afterward.

The command below confirms the ACL. It runs as the applier's own identity through the Cloud SQL Admin API, the same as any provision script, rather than as a human over a direct connection this PSC-only instance has no path for.

```
gcloud sql instances execute-sql dfo-dev-platform-postgres \
  --project=dev-fin-observatory \
  --database=postgres \
  --sql="SELECT datname, pg_get_userbyid(datdba) AS owner, datacl FROM pg_database WHERE datname IN ('postgres', 'datasets') ORDER BY datname;"
```

On the `postgres` row, PUBLIC's entry reads `=T/...` (TEMP only, no `c`), the owner entry `cloudsqlsuperuser=CTc/cloudsqlsuperuser` is present, and an entry for the applier with `c` exists.

A database created fresh through the Admin API starts with a NULL `datacl`, which leaves PUBLIC holding CONNECT on it. That gap is the break-glass path back into `postgres` if the applier's own CONNECT is ever lost.

```
gcloud sql databases create acl-rescue --instance=dfo-dev-platform-postgres --project=dev-fin-observatory
gcloud sql instances execute-sql dfo-dev-platform-postgres --project=dev-fin-observatory \
  --database=acl-rescue \
  --sql='GRANT CONNECT ON DATABASE "postgres" TO "dfo-infra-applier@dev-fin-observatory.iam";'
gcloud sql databases delete acl-rescue --instance=dfo-dev-platform-postgres --project=dev-fin-observatory
```

`pg_database` is a shared catalog, so a GRANT against `postgres` works from any database on the instance, including this freshly created one. The applier is the identity for this procedure. The built-in `postgres` user carries no SUPERUSER attribute, so it fails in the same scenarios the applier would.
