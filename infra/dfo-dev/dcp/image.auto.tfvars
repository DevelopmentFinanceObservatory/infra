# Machine-owned: dfo-dcp's deploy workflow force-pushes this repo's
# deploy/dcp-dev branch and opens a PR that changes only the line below.
#
# Split out of dfo.auto.tfvars so CODEOWNERS can carve it out of code-owner
# review. Do not add a second variable here: anything else placed in this
# file inherits that unowned status and merges without review. Other
# committed, non-secret dcp config belongs in dfo.auto.tfvars.
datacommons_services_image = "northamerica-northeast1-docker.pkg.dev/dev-fin-observatory/datacommons/dfo-services-image@sha256:fc2bc7a8511c6188a256db4ecc83ad20180e8f958e04c59de3cbafa6ceaea7f7"
