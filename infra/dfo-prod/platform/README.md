# platform (prod)

Prod's copy of the platform stack, the shared Cloud SQL Postgres instance. The `.tf` files are symlinks to `infra/stacks/platform`; `infra/dfo-dev/platform/README.md` describes what they build. This directory holds prod's backend, tfvars, and lock file.

`env.auto.tfvars` sets `tier = "db-custom-2-7680"`, two dedicated vCPUs and 7.5 GB, where dev runs one vCPU and 3.75 GB. The instance is zonal, like dev's.

## Apply order

Platform applies second, after `foundation`, and before the tenant stacks (`dcp`, `apis`, `ai`, `website`) that create databases on its instance.

## Made by hand first

Nothing beyond foundation's prerequisites. The stack reads the `dfo-infra-applier` service account, which foundation creates.
