# Machine-owned: dfo-dcp's deploy workflow force-pushes this repo's
# deploy/dcp-dev branch and opens a PR that changes only the line below.
#
# Split out of dfo.auto.tfvars so CODEOWNERS can carve it out of code-owner
# review. Do not add a second variable here: anything else placed in this
# file inherits that unowned status and merges without review. Other
# committed, non-secret dcp config belongs in dfo.auto.tfvars.
datacommons_services_image = "northamerica-northeast1-docker.pkg.dev/dev-fin-observatory/datacommons/dfo-services-image@sha256:593465933382fe52bfac999e43002e4e81124eb035ebc2ef9952c9a2436d9256"
