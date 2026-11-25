# pipelines (prod)

Prod's copy of the pipelines stack: the landing and exports buckets and the BigQuery datasets. The `.tf` files are symlinks to `infra/stacks/pipelines`; `infra/dfo-dev/pipelines/README.md` describes what they build. This directory holds prod's backend, tfvars, and lock file.

Prod runs in `europe-west1`, with the other prod stacks. Dev's pipelines stack is in `northamerica-northeast1`.
