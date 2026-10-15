# Machine-owned: dfo-dcp's deploy workflow force-pushes this repo's
# deploy/dcp-prod branch and opens a PR that changes only the line below.
#
# null makes main.tf fall back to upstream's image for dcp_version, until the
# first pin PR merges. Do not add a second variable here: other committed,
# non-secret dcp config belongs in dfo.auto.tfvars.
datacommons_services_image = "europe-west1-docker.pkg.dev/prod-fin-observatory/datacommons/dfo-services-image@sha256:a37ffd1ecb3dff6af912592589c57cb48320bb569b1e8cb255edde2b828c6805"
