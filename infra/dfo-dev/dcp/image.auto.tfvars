# Machine-owned: dfo-dcp's deploy workflow force-pushes this repo's
# deploy/dcp-dev branch and opens a PR that changes only the line below.
#
# Split out of dfo.auto.tfvars so CODEOWNERS can carve it out of code-owner
# review. Do not add a second variable here: anything else placed in this
# file inherits that unowned status and merges without review. Other
# committed, non-secret dcp config belongs in dfo.auto.tfvars.
datacommons_services_image = "northamerica-northeast1-docker.pkg.dev/dev-fin-observatory/datacommons/dfo-services-image@sha256:8848e98280dd52db10cc8e935feefbd4d74f7b4cd4f5effabf3cba54be2ef23f"
