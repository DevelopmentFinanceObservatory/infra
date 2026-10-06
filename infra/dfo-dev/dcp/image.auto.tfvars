# Machine-owned: dfo-dcp's deploy workflow force-pushes this repo's
# deploy/dcp-dev branch and opens a PR that changes only the line below.
#
# Split out of dfo.auto.tfvars so CODEOWNERS can carve it out of code-owner
# review. Do not add a second variable here: anything else placed in this
# file inherits that unowned status and merges without review. Other
# committed, non-secret dcp config belongs in dfo.auto.tfvars.
datacommons_services_image = "northamerica-northeast1-docker.pkg.dev/dev-fin-observatory/datacommons/dfo-services-image@sha256:f53732d02a3112cbbbbfa2d5414796a15105dae0fc0cceadf6e4624e652503a9"
