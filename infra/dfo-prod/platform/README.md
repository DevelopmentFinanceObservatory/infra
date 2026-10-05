# platform (prod)

Prod's copy of the platform stack, the shared Cloud SQL Postgres instance. The `.tf` files are symlinks to `infra/stacks/platform`; `infra/dfo-dev/platform/README.md` describes what they build. This directory holds prod's backend, tfvars, and lock file.

## Apply order

Platform applies second, after `foundation`, and before the tenant stacks (`dcp`, `apis`, `ai`, `website`) that create databases on its instance.

## Made by hand first

Nothing beyond foundation's prerequisites. The stack reads the `dfo-infra-applier` service account, which foundation creates.
